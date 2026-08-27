//
//  KokoroEngine+LoadingAndSelection.swift
//

import Foundation
import AVFoundation
@preconcurrency import CoreML
import Accelerate

extension KokoroEngine {

    // MARK: - Loading

    /// Load models from the kokoro resource directory.
    ///
    /// Expected layout:
    /// ```
    /// modelsDir/
    ///   kokoro_24_10s.mlmodelc    (or .mlpackage)  — any known variant, ≥1 required
    ///   vocab_index.json
    ///   us_gold.json
    ///   us_silver.json            (optional, adds coverage)
    ///   voices/
    ///     af_heart.json
    ///     ...
    /// ```
    ///
    /// - Parameter variants: Explicit list of variant names to load (e.g. `["kokoro_24_10s",
    ///   "kokoro_24_15s"]`). Pass an empty array (the default) to auto-discover and load every
    ///   variant whose model file is present in `modelsDir`.
    ///
    /// At synthesis time the engine automatically selects the smallest loaded variant whose
    /// token window fits the input, so short utterances use the fastest model and long ones
    /// never get truncated unnecessarily.
    public func loadModels(
        from modelsDir: URL,
        variants: [String] = [],
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) async throws {
        observeConfigurationChangesIfNeeded()
        modelsDirectory = modelsDir

        // Resolve the set of variants to attempt — explicit list or every known variant.
        let names = variants.isEmpty
            ? TTSConfig.variants.map(\.name)
            : variants

        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits

        var newModels: [LoadedModel] = []

        for variantName in names {
            guard let variantConfig = TTSConfig.variants.first(where: { $0.name == variantName }) else {
                print("⚠️ Unknown variant '\(variantName)' — skipping")
                continue
            }
            guard let modelURL = findModelURL(variantName, in: modelsDir) else {
                if !variants.isEmpty {
                    // Caller explicitly requested this variant — treat as error.
                    throw TTSError.modelLoadFailed("\(variantName) not found in \(modelsDir.path)")
                }
                // Auto-discovery: variant simply isn't present, skip silently.
                continue
            }

            print("📦 Loading model: \(modelURL.lastPathComponent)")
            let compiled    = try await compileIfNeeded(modelURL)
            let loadedModel = try MLModel(contentsOf: compiled, configuration: cfg)

            // Read actual shapes from model metadata — overrides hardcoded config values.
            // (e.g. kokoro_21_10s uses 249 tokens, not 242)
            let desc = loadedModel.modelDescription
            var resolvedTokens  = variantConfig.maxTokens
            var resolvedSamples = variantConfig.maxSamples
            if let tokenShape = desc.inputDescriptionsByName["input_ids"]?.multiArrayConstraint?.shape,
               tokenShape.count >= 2 {
                resolvedTokens = tokenShape[1].intValue
            }
            if let audioShape = desc.outputDescriptionsByName["audio"]?.multiArrayConstraint?.shape,
               audioShape.count >= 3 {
                resolvedSamples = audioShape[2].intValue
            }

            // Build a resolved variant reflecting the model's actual I/O shapes.
            let resolved = TTSVariant(
                name:       variantConfig.name,
                sampleRate: variantConfig.sampleRate,
                maxTokens:  resolvedTokens,
                maxSamples: resolvedSamples
            )
            print("✅ \(variantName) — maxTokens: \(resolvedTokens), maxSamples: \(resolvedSamples), sampleRate: \(variantConfig.sampleRate)")
            newModels.append(LoadedModel(variant: resolved, model: loadedModel))
        }

        guard !newModels.isEmpty else {
            throw TTSError.modelLoadFailed("No model files found in \(modelsDir.path)")
        }

        // Sort ascending by audio window so selectModel() can do a simple
        // first-match scan (the exported variants share a 242-token window
        // and differ in how many seconds of audio they can emit).
        loadedModels = newModels.sorted { $0.variant.maxSamples < $1.variant.maxSamples }
        // Expose the largest model's sample rate as the default (updated per-synthesis call).
        sampleRate = loadedModels.last!.variant.sampleRate

        let vocabURL = modelsDir.appendingPathComponent("vocab_index.json")
        try phonemizer.loadVocab(from: vocabURL)

        for name in ["us_gold.json", "gb_gold.json", "us_silver.json", "gb_silver.json"] {
            let url = modelsDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try phonemizer.loadLexicon(from: url)
            }
        }

        // Load G2P model (optional — silently skipped if files are absent).
        await loadG2PIfAvailable(in: modelsDir, computeUnits: computeUnits)

        // Seed known proper-noun pronunciations that the English lexicon omits.
        seedBuiltInProperNouns()

        isLoaded = true
    }

    func loadG2PIfAvailable(in modelsDir: URL, computeUnits: MLComputeUnits) async {
        let vocabURL  = modelsDir.appendingPathComponent("g2p_vocab.json")
        let cacheURL  = modelsDir.appendingPathComponent("us_lexicon_cache.json")

        // Use findModelURL so both .mlpackage and compiled .mlmodelc are found.
        guard let encoderURL = findModelURL("G2PEncoder", in: modelsDir),
              let decoderURL = findModelURL("G2PDecoder", in: modelsDir),
              FileManager.default.fileExists(atPath: vocabURL.path) else {
            print("ℹ️ G2P models not found — skipping")
            return
        }

        do {
            try g2p.loadVocab(from: vocabURL)

            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try await g2p.loadLexiconCache(from: cacheURL)
            }

            try await g2p.loadModels(encoderURL: encoderURL, decoderURL: decoderURL,
                                     computeUnits: computeUnits)
            phonemizer.g2p = g2p
            print("✅ G2P pipeline active")
        } catch {
            print("⚠️ G2P load failed (continuing without it): \(error)")
        }
    }

    // MARK: - Model selection

    /// Speech runs ≈17 phoneme tokens per second, so a dense 242-token input
    /// produces ~14 s of audio — past the 10 s model's window, which would
    /// CLIP the tail. Selection therefore honors both the token window and
    /// the estimated audio duration.
    static let phonemeTokensPerSecond: Double = 17

    /// Returns the smallest loaded model that fits `tokenCount` in its token
    /// window AND its audio window (estimated). Falls back to the largest.
    func selectModel(for tokenCount: Int) -> LoadedModel? {
        let estimatedSeconds = Double(tokenCount) / Self.phonemeTokensPerSecond
        return loadedModels.first {
            $0.variant.maxTokens >= tokenCount
                && Double($0.variant.maxSamples) / $0.variant.sampleRate >= estimatedSeconds
        } ?? loadedModels.last
    }

    /// IPA for proper nouns / names that the CMU/gold lexicons don't cover.
    ///
    /// HER OWN NAME IS NOT IN HERE, and its absence is the point. An override
    /// is for a word the lexicons miss; "Mary" is ordinary English and the
    /// gold lexicon has it (`mˈɛɹi`, the same vowel it gives "merry" and
    /// "marry"), so an entry here could only ever disagree with it. Seeding
    /// one would also put the assistant's name in exactly the place a rename
    /// cannot reach — a spelling sweep rewrites the key and leaves the IPA
    /// saying the old name out loud, which is precisely how this was found.
    func seedBuiltInProperNouns() {
        // The user's name, as they pronounce it: R-eh-TESH PAA-ka-la Rao
        // (Rao rhymes with cow; capital W is the aʊ diphthong in this vocab).
        // Possessives compose free via the morphology tier.
        phonemizer.addCustomPronunciation("Ritesh", ipa: "ɹɛtˈɛʃ")
        phonemizer.addCustomPronunciation("Pakala", ipa: "pˈɑkɑlɑ")
        phonemizer.addCustomPronunciation("Rao", ipa: "ɹˈW")
        // Kept from the source port as a worked example of the override mechanism.
        phonemizer.addCustomPronunciation("Marielle", ipa: "mɑːriɛl")
    }

    /// Register a pronunciation override for any word the built-in lexicon mispronounces.
    ///
    /// Uses Kokoro IPA notation (same character set as the loaded vocab). Example:
    /// ```swift
    /// await engine.addCustomPronunciation("Marielle", ipa: "mɑːriɛl")
    /// ```
    /// The override persists for the lifetime of this engine instance.
    public func addCustomPronunciation(_ word: String, ipa: String) {
        phonemizer.addCustomPronunciation(word, ipa: ipa)
    }

    public func loadVoice(named name: String, in modelsDir: URL) throws {
        currentVoice = try KokoroVoice.load(named: name, in: modelsDir)
        print("🎙️ Voice loaded: \(currentVoice!.name)")
    }

    /// Voice names available in `<modelsDir>/voices/`.
    public nonisolated static func availableVoices(in modelsDir: URL) -> [String] {
        let voicesDir = modelsDir.appendingPathComponent("voices")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: voicesDir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

}

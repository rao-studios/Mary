//
//  KokoroEngine+LoadingAndSelection.swift
//  MaryVoice
//
//  WHAT: Load models, pick variant, seed proper-noun IPA.
//  IN:   KokoroEngine.swift (same actor)
//  OUT:  loadedModels / phonemizer / g2p
//

import Foundation
import AVFoundation
@preconcurrency import CoreML
import Accelerate

extension KokoroEngine {

    // MARK: - Loading

    /// Load models from the kokoro resource directory.
    /// Layout: kokoro_*.mlmodelc, vocab_index.json, us_gold.json, us_silver.json?, voices/*.json
    /// Empty `variants` = auto-discover every present model. Synthesis picks the smallest fit.
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

    /// ≈17 phoneme tokens/s — selection honors both token window and estimated duration.
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

    /// IPA for proper nouns the gold lexicons omit. PIN: do not seed "Mary"
    /// (ordinary English; a rename would leave the old IPA speaking).
    func seedBuiltInProperNouns() {
        // User's name, as pronounced. Possessives compose via morphology.
        phonemizer.addCustomPronunciation("Ritesh", ipa: "ɹɛtˈɛʃ")
        phonemizer.addCustomPronunciation("Pakala", ipa: "pˈɑkɑlɑ")
        phonemizer.addCustomPronunciation("Rao", ipa: "ɹˈW")
        // Kept from the source port as a worked example of the override mechanism.
        phonemizer.addCustomPronunciation("Marielle", ipa: "mɑːriɛl")
    }

    /// IPA override for this engine instance. Same character set as the loaded vocab.
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

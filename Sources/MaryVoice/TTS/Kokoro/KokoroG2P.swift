//
//  KokoroG2P.swift
//  MaryVoice — on-device Grapheme-to-Phoneme inference (CoreML BART-style
//  encoder-decoder from FluidAudio's kokoro-82m-coreml export) plus the 178k
//  pre-computed cache.
//
//  Lookup priority for a given word:
//    1. us_lexicon_cache  — caseSensitive section (NASA, OK), then lower
//    2. G2PEncoder + greedy G2PDecoder — for any word not in the cache
//
//  Invocation matches FluidAudio's shipping G2PModel.swift exactly:
//
//  Encoder:
//    input_ids [1, encLen] Int32 — [BOS] + grapheme ids + [EOS], no padding
//    → encoder_hidden_states [1, encLen, hidden] Float32
//
//  Decoder (greedy, one step per iteration, max 64):
//    decoder_input_ids [1, decLen] Int32     — starts [BOS]
//    encoder_hidden_states                    — from the encoder
//    position_ids [1, decLen] Int32           — values i + 2 (BART offset)
//    causal_mask [1, decLen, decLen] Float32  — j > i ? -1e4 : 0
//    → logits [1, decLen, nPhone]; argmax last position; stop on EOS.
//  Assembly skips all special tokens {pad, bos, eos, unk}.
//
//  Measured (mary-voice-probe g2p-validate, 500 cache pairs, seed 42):
//  exact 73.6%, close 87.8%, mean edit distance 0.53.
//
//  ⚠️ Load-bearing: logits MUST be read via stride-aware subscripting —
//  this converter emits non-contiguous MLMultiArrays, and dataPointer
//  indexing silently reads garbage (empty output, no error). Compute units
//  need no special-casing: the ANE compiler declines these dynamic-shape
//  models with a harmless E5RT console warning and CoreML falls back to
//  CPU transparently (~2-4 ms per word). (The previous SeerTTS-era models
//  were a broken export: 0% exact, different interface. g2p-validate gates
//  any future model swap.)
//

import Foundation
@preconcurrency import CoreML

final class KokoroG2P {

    // MARK: - Vocab

    /// grapheme char → encoder input ID
    private var graphemeToID: [Character: Int32] = [:]
    /// decoder output ID → IPA char string (from id_to_phoneme)
    private var idToPhoneme:  [Int: String]       = [:]

    private var bosID: Int32 = 1
    private var eosID: Int32 = 2
    private var padID: Int32 = 0
    private var unkID: Int32 = 3

    // MARK: - Cache

    /// word.lowercased() → joined IPA string (pre-computed G2P results)
    private var cache: [String: String] = [:]
    /// Exact-case entries: NASA, OK, A's, …
    private var caseCache: [String: String] = [:]
    /// Session memo of neural results — including nil misses, so a failing
    /// word is never re-decoded within a session.
    private var memo: [String: String?] = [:]

    // MARK: - Models

    private var encoder:    MLModel?
    private var decoder:    MLModel?

    var isLoaded: Bool { encoder != nil && decoder != nil && !graphemeToID.isEmpty }
    var cacheCount: Int { cache.count }

    // MARK: - Loading

    /// Load grapheme and phoneme vocab from `g2p_vocab.json`.
    func loadVocab(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let g2id = json["grapheme_to_id"] as? [String: Int] {
            for (ch, id) in g2id {
                // Skip multi-char special tokens (<pad>, <s>, </s>, <unk>) —
                // taking .first would collapse them all onto '<'.
                guard ch.count == 1, let c = ch.first else { continue }
                graphemeToID[c] = Int32(id)
            }
        }
        if let idPh = json["id_to_phoneme"] as? [String: String] {
            for (idStr, ph) in idPh {
                if let id = Int(idStr) { idToPhoneme[id] = ph }
            }
        }
        if let bos = json["bos_token_id"] as? Int { bosID = Int32(bos) }
        if let eos = json["eos_token_id"] as? Int { eosID = Int32(eos) }
        if let pad = json["pad_token_id"] as? Int { padID = Int32(pad) }
    }

    /// Load pre-computed word → phoneme entries from `us_lexicon_cache.json` —
    /// both the `lower` and `caseSensitive` sections.
    /// Parsed on a background thread to avoid blocking the caller.
    func loadLexiconCache(from url: URL) async throws {
        let (lower, exact): ([String: String], [String: String]) = try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ([:], [:])
            }
            func parse(_ section: Any?) -> [String: String] {
                guard let dict = section as? [String: Any] else { return [:] }
                var result = [String: String]()
                result.reserveCapacity(dict.count)
                for (word, value) in dict {
                    if let arr = value as? [String] { result[word] = arr.joined() }
                }
                return result
            }
            return (parse(root["lower"]), parse(root["caseSensitive"]))
        }.value
        self.cache = lower
        self.caseCache = exact
    }

    /// Load the G2PEncoder and G2PDecoder CoreML models. Any compute units
    /// work: the ANE compiler declines these dynamic-shape models with a
    /// harmless E5RT console warning and CoreML falls back to CPU, where a
    /// word decodes in ~2-4 ms.
    func loadModels(encoderURL: URL, decoderURL: URL,
                    computeUnits: MLComputeUnits = .cpuAndNeuralEngine) async throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits

        let encURL = try await compileIfNeeded(encoderURL)
        let enc    = try MLModel(contentsOf: encURL, configuration: cfg)
        let decURL = try await compileIfNeeded(decoderURL)
        let dec    = try MLModel(contentsOf: decURL, configuration: cfg)

        self.encoder = enc
        self.decoder = dec
        // A model reload invalidates memoized neural results.
        memo = [:]
    }

    // MARK: - Cache lookups (synchronous, deterministic)

    /// Lowercase-section cache hit.
    func cachedPhonemes(for word: String) -> String? {
        cache[word.lowercased()]
    }

    /// Exact-case cache hit (NASA, OK, A's, …).
    func caseSensitiveCachedPhonemes(for word: String) -> String? {
        caseCache[word]
    }

    // MARK: - Inference

    /// Cache → memo → neural model (the classic combined entry point).
    func phonemes(for word: String) async -> String? {
        let lower = word.lowercased()
        if let cached = cache[lower] { return cached }
        return await modelPhonemes(for: lower)
    }

    /// Neural model only (memoized). Returns nil when the model is unloaded
    /// or produces nothing.
    func modelPhonemes(for word: String) async -> String? {
        let lower = word.lowercased()
        if let memoized = memo[lower] {
            return memoized
        }
        guard isLoaded else { return nil }
        let result = await runG2P(lower)
        memo[lower] = result
        return result
    }

    // MARK: - Private: G2P model inference (FluidAudio interface)

    private func runG2P(_ word: String) async -> String? {
        guard let encoder, let decoder else { return nil }

        // 1. Encoder input: [BOS] + grapheme ids + [EOS], variable length.
        var inputIDs: [Int32] = [bosID]
        for ch in word {
            inputIDs.append(graphemeToID[ch] ?? unkID)
        }
        inputIDs.append(eosID)
        let encLen = min(inputIDs.count, 64)
        inputIDs = Array(inputIDs.prefix(encLen))

        guard let encIDs = try? MLMultiArray(shape: [1, NSNumber(value: encLen)], dataType: .int32)
        else { return nil }
        let encPtr = encIDs.dataPointer.bindMemory(to: Int32.self, capacity: encLen)
        for (i, id) in inputIDs.enumerated() { encPtr[i] = id }

        // 2. Run encoder → encoder_hidden_states.
        let encResult: MLFeatureProvider
        do {
            encResult = try await encoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: encIDs),
                ]))
        } catch {
            return nil
        }
        guard let hiddenState = encResult.featureValue(for: "encoder_hidden_states")?.multiArrayValue
        else { return nil }

        // 3. Greedy decode from [BOS].
        var decTokens: [Int32] = [bosID]
        let maxSteps = 64

        for _ in 0..<maxSteps {
            let decLen = decTokens.count
            guard let decIDs = try? MLMultiArray(shape: [1, NSNumber(value: decLen)], dataType: .int32),
                  let posIDs = try? MLMultiArray(shape: [1, NSNumber(value: decLen)], dataType: .int32),
                  let mask = try? MLMultiArray(
                    shape: [1, NSNumber(value: decLen), NSNumber(value: decLen)], dataType: .float32)
            else { break }

            let decPtr = decIDs.dataPointer.bindMemory(to: Int32.self, capacity: decLen)
            let posPtr = posIDs.dataPointer.bindMemory(to: Int32.self, capacity: decLen)
            for (i, t) in decTokens.enumerated() {
                decPtr[i] = t
                posPtr[i] = Int32(i + 2)   // BART position offset
            }
            let maskPtr = mask.dataPointer.bindMemory(to: Float.self, capacity: decLen * decLen)
            for i in 0..<decLen {
                for j in 0..<decLen {
                    maskPtr[i * decLen + j] = j > i ? -1e4 : 0
                }
            }

            let decResult: MLFeatureProvider
            do {
                decResult = try await decoder.prediction(
                    from: MLDictionaryFeatureProvider(dictionary: [
                        "decoder_input_ids":     MLFeatureValue(multiArray: decIDs),
                        "encoder_hidden_states": MLFeatureValue(multiArray: hiddenState),
                        "position_ids":          MLFeatureValue(multiArray: posIDs),
                        "causal_mask":           MLFeatureValue(multiArray: mask),
                    ]))
            } catch {
                break
            }
            guard let logits = decResult.featureValue(for: "logits")?.multiArrayValue
            else { break }

            // logits: [1, decLen, nPhone] — argmax at the last position.
            // Stride-aware subscripting, NOT dataPointer: this converter
            // emits non-contiguous arrays, and raw indexing reads garbage.
            let nPhone = logits.shape.count >= 3 ? logits.shape[2].intValue : logits.count / decLen
            var bestID  = 0
            var bestVal = -Float.infinity
            for v in 0..<nPhone {
                let val = logits[[0, decLen - 1, v] as [NSNumber]].floatValue
                if val > bestVal { bestVal = val; bestID = v }
            }

            if Int32(bestID) == eosID { break }
            decTokens.append(Int32(bestID))
        }

        // 4. Assemble, skipping every special token.
        let specials: Set<Int32> = [padID, bosID, eosID, unkID]
        var ipa = ""
        for id in decTokens where !specials.contains(id) {
            if let ph = idToPhoneme[Int(id)], !ph.hasPrefix("<") { ipa += ph }
        }

        return ipa.isEmpty ? nil : ipa
    }

    // MARK: - Validation

    struct ValidationResult: Sendable {
        var configName: String
        var sampleCount: Int
        var exactMatches: Int
        var closeMatches: Int      // scalar-level edit distance ≤ 1
        var meanEditDistance: Double
        var worst: [(word: String, expected: String, got: String)]

        var summary: String {
            let exactPct = sampleCount > 0 ? 100.0 * Double(exactMatches) / Double(sampleCount) : 0
            let closePct = sampleCount > 0 ? 100.0 * Double(closeMatches) / Double(sampleCount) : 0
            return String(
                format: "%@  exact %.1f%%  close %.1f%%  meanEdit %.2f  (n=%d)",
                configName.padding(toLength: 28, withPad: " ", startingAt: 0),
                exactPct, closePct, meanEditDistance, sampleCount
            )
        }
    }

    /// Deterministically sample (word, expectedIPA) ground-truth pairs from
    /// the lowercase cache.
    func sampleCachePairs(count: Int, seed: UInt64) -> [(word: String, ipa: String)] {
        let words = cache.keys.sorted()
        guard !words.isEmpty else { return [] }
        var rng = SplitMix64(seed: seed)
        var pairs: [(String, String)] = []
        pairs.reserveCapacity(count)
        for _ in 0..<count {
            let word = words[Int(rng.next() % UInt64(words.count))]
            if let ipa = cache[word] {
                pairs.append((word, ipa))
            }
        }
        return pairs
    }

    /// Score the neural model against ground-truth pairs.
    func validate(
        pairs: [(word: String, ipa: String)],
        configName: String = "fluidaudio-bos"
    ) async -> ValidationResult {
        var exact = 0
        var close = 0
        var totalDistance = 0
        var scored: [(String, String, String, Int)] = []

        for (word, expected) in pairs {
            memo[word.lowercased()] = nil   // never let memoization skew scores
            let got = await modelPhonemes(for: word) ?? ""
            let distance = Self.editDistance(expected, got)
            if distance == 0 { exact += 1 }
            if distance <= 1 { close += 1 }
            totalDistance += distance
            scored.append((word, expected, got, distance))
        }

        let worst = scored.sorted { $0.3 > $1.3 }.prefix(5).map { ($0.0, $0.1, $0.2) }
        return ValidationResult(
            configName: configName,
            sampleCount: pairs.count,
            exactMatches: exact,
            closeMatches: close,
            meanEditDistance: pairs.isEmpty ? 0 : Double(totalDistance) / Double(pairs.count),
            worst: Array(worst)
        )
    }

    /// Scalar-level Levenshtein distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a.unicodeScalars)
        let t = Array(b.unicodeScalars)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[t.count]
    }

    // MARK: - Compile helper

    private func compileIfNeeded(_ url: URL) async throws -> URL {
        if url.pathExtension == "mlmodelc" { return url }
        let compiled = try await MLModel.compileModel(at: url)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dest     = cacheDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mlmodelc")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: compiled, to: dest)
        return dest
    }
}

/// Tiny deterministic RNG for reproducible validation sampling.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

//
//  KokoroVoice.swift
//  MaryVoice
//
//  Faithful port of SeerTTS/KokoroTTSDemo.
//

import Foundation
import Accelerate

// MARK: - Voice

/// Kokoro voice style embedding loaded from a JSON file.
///
/// The voice JSON is keyed by phoneme count (e.g. `{"1": [...], "2": [...], ..., "510": [...]}`).
/// The correct embedding for a given synthesis call is selected by the number of input tokens
/// (BOS + phonemes + EOS, before zero-padding). This matches FluidAudio's approach exactly.
///
/// Note: embeddings are used as-is without L2 normalization — the voice files are pre-conditioned.
final class KokoroVoice {
    let name: String
    private let json: Any

    private init(name: String, json: Any) {
        self.name = name
        self.json = json
    }

    /// Load a voice from `<modelsDir>/<name>.json`.
    static func load(named name: String, in modelsDir: URL) throws -> KokoroVoice {
        let url = modelsDir.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TTSError.invalidVoiceFile("'\(name).json' not found at \(url.path)")
        }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        return KokoroVoice(name: name, json: json)
    }

    /// Return the 256-dim style vector for the given phoneme count.
    ///
    /// Lookup priority (mirrors FluidAudio's `parseVoiceEmbeddingVector`):
    ///   1. Direct flat array
    ///   2. Dict key `"embedding"`
    ///   3. Dict key matching `voiceName`
    ///   4. Numeric dict key — exact match, then closest lower, then any
    func embedding(for phonemeCount: Int) -> [Float]? {
        parseVector(from: json, phonemeCount: phonemeCount)
    }

    // MARK: - Private

    private func parseVector(from json: Any, phonemeCount: Int) -> [Float]? {
        if let direct = asFloatArray(json) { return direct }

        guard let dict = json as? [String: Any] else { return nil }

        if let embed = dict["embedding"], let v = asFloatArray(embed) { return v }
        if let voiceSpecific = dict[name], let v = asFloatArray(voiceSpecific) { return v }

        // Numeric keys — exact match, then closest lower, then any
        var candidates: [(Int, [Float])] = []
        for (key, value) in dict {
            guard let intKey = Int(key), let v = asFloatArray(value) else { continue }
            candidates.append((intKey, v))
        }
        candidates.sort { $0.0 < $1.0 }

        if let exact = candidates.first(where: { $0.0 == phonemeCount }) { return exact.1 }
        if let lower = candidates.last(where: { $0.0 <= phonemeCount }) { return lower.1 }
        return candidates.first?.1
    }

    private func asFloatArray(_ value: Any) -> [Float]? {
        if let doubles = value as? [Double]   { return doubles.map(Float.init) }
        if let floats  = value as? [Float]    { return floats }
        if let numbers = value as? [NSNumber] { return numbers.map { $0.floatValue } }
        if let anyArr  = value as? [Any] {
            var out = [Float](); out.reserveCapacity(anyArr.count)
            for item in anyArr {
                if let n = item as? NSNumber    { out.append(n.floatValue) }
                else if let d = item as? Double { out.append(Float(d)) }
                else if let f = item as? Float  { out.append(f) }
                else { return nil }
            }
            return out
        }
        return nil
    }
}

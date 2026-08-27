//
//  KokoroTTSConfig.swift
//  MaryVoice
//
//  Faithful port of SeerTTS/KokoroTTSDemo. Model variant table and errors.
//

import CoreML

// MARK: - Model I/O
//
// INPUTS:
//   input_ids:      [1, maxTokens]  Int32    — phoneme token IDs, BOS(0)+ids+EOS(0), zero-padded
//   ref_s:          [1, 256]        Float32  — L2-normalized voice embedding
//   random_phases:  [1, 9]         Float32  — iSTFT phase seeds (MUST be zeroed)
//   attention_mask: [1, maxTokens]  Int32    — 1=real token (including BOS/EOS), 0=pad
//
// OUTPUTS:
//   audio:                [1, 1, maxSamples] Float32  — waveform @ sampleRate
//   audio_length_samples: [1]                Int32    — exact sample count

// MARK: - Variant

public struct TTSVariant: Sendable {
    public let name:       String
    public let sampleRate: Double
    public let maxTokens:  Int
    public let maxSamples: Int
}

// MARK: - Config

public enum TTSConfig {
    public static let voiceDim: Int = 256

    /// All known variants. Mary vendors only kokoro_24_10s; auto-discovery
    /// tolerates absent variants, so the full table stays declared.
    public static let variants: [TTSVariant] = [
        // 24 kHz family
        TTSVariant(name: "kokoro_24_5s",  sampleRate: 24_000, maxTokens: 121, maxSamples: 120_000),
        TTSVariant(name: "kokoro_24_10s", sampleRate: 24_000, maxTokens: 242, maxSamples: 240_000),
        TTSVariant(name: "kokoro_24_15s", sampleRate: 24_000, maxTokens: 363, maxSamples: 360_000),
        // 21 kHz family
        TTSVariant(name: "kokoro_21_5s",  sampleRate: 21_000, maxTokens: 121, maxSamples: 105_000),
        TTSVariant(name: "kokoro_21_10s", sampleRate: 21_000, maxTokens: 242, maxSamples: 210_000),
        TTSVariant(name: "kokoro_21_15s", sampleRate: 21_000, maxTokens: 363, maxSamples: 315_000),
    ]
}

// MARK: - Errors

public enum TTSError: LocalizedError {
    case modelsNotLoaded
    case noVoiceLoaded
    case phonemizationFailed
    case audioConversionFailed
    case modelLoadFailed(String)
    case predictionFailed(String)
    case invalidVoiceFile(String)

    public var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:         return "Models not loaded."
        case .noVoiceLoaded:           return "No voice loaded."
        case .phonemizationFailed:     return "Phonemization failed."
        case .audioConversionFailed:   return "Audio conversion failed."
        case .modelLoadFailed(let d):  return "Model load failed: \(d)"
        case .predictionFailed(let d): return "Prediction failed: \(d)"
        case .invalidVoiceFile(let n): return "Invalid voice file: \(n)"
        }
    }
}

//
//  VoicePipelineConfig.swift
//  MaryVoice
//
//  WHAT: Tunable loop knobs. Settings exposes them; the probe can sweep them.
//  IN:   Settings / probe / VoicePipeline.init
//  OUT:  STTBackend / TTSBackend / VADConfig / VoicePipeline
//

import Foundation

/// STT backend. Both are Apple and on-device; they differ in the model.
public enum STTBackend: String, Sendable, Codable, CaseIterable {
    /// SFSpeechRecognizer — the classic on-device recognizer, live partials.
    case apple
    /// SpeechAnalyzer + SpeechTranscriber — the macOS 26 model, flushed through end of input.
    case analyzer

    public var displayName: String {
        switch self {
        case .apple:    return "Speech (classic recognizer)"
        case .analyzer: return "SpeechAnalyzer (newer on-device model)"
        }
    }
}

/// TTS backend the speaker synthesizes with.
public enum TTSBackend: String, Sendable, Codable, CaseIterable {
    /// Kokoro CoreML, on-device.
    case kokoro
    /// Local Sewn `/v1/speak` — signed-in session. PIN: all cloud voice goes here.
    case sewn

    public var displayName: String {
        switch self {
        case .kokoro: return "Kokoro (on-device)"
        case .sewn:   return "Sewn (local server)"
        }
    }
}

/// Energy-VAD endpointing thresholds. OUT: EnergyVAD / BargeInGovernor.
public struct VADConfig: Sendable, Codable, Equatable {
    /// RMS above this opens an utterance.
    public var speechStartRMS: Float
    /// RMS above this keeps an open utterance alive (hysteresis below start).
    public var speechContinueRMS: Float
    /// Trailing silence that closes an utterance.
    public var hangoverMs: Int
    /// Shorter bursts than this are discarded as noise.
    public var minUtteranceMs: Int
    /// Audio kept from before speechStart and replayed into STT. Not persisted:
    /// nobody tunes it, and a stored value would pin an old default forever.
    public var preRollMs: Int
    /// While Kokoro speaks, multiply speechStartRMS by this. Barge-in must beat it.
    public var bargeInRMSBoost: Float
    /// Quiet after a provisional barge-in pause before playback resumes (noise, not speech).
    public var bargeResumeMs: Int
    /// Apple voice processing (echo cancel) so full-duplex ignores Mary's speaker.
    public var voiceProcessing: Bool

    public init(
        speechStartRMS: Float = 0.015,
        speechContinueRMS: Float = 0.008,
        hangoverMs: Int = 850,
        minUtteranceMs: Int = 300,
        preRollMs: Int = 600,
        bargeInRMSBoost: Float = 3.0,
        bargeResumeMs: Int = 500,
        voiceProcessing: Bool = true
    ) {
        self.speechStartRMS = speechStartRMS
        self.speechContinueRMS = speechContinueRMS
        self.hangoverMs = hangoverMs
        self.minUtteranceMs = minUtteranceMs
        self.preRollMs = preRollMs
        self.bargeInRMSBoost = bargeInRMSBoost
        self.bargeResumeMs = bargeResumeMs
        self.voiceProcessing = voiceProcessing
    }

    /// `preRollMs` is deliberately absent — see its doc comment.
    enum CodingKeys: String, CodingKey {
        case speechStartRMS, speechContinueRMS, hangoverMs, minUtteranceMs,
             bargeInRMSBoost, bargeResumeMs, voiceProcessing
    }

    /// Tolerant decode — persisted in the app config store; new fields must not fail old restores.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speechStartRMS = try c.decodeIfPresent(Float.self, forKey: .speechStartRMS) ?? 0.015
        speechContinueRMS = try c.decodeIfPresent(Float.self, forKey: .speechContinueRMS) ?? 0.008
        hangoverMs = try c.decodeIfPresent(Int.self, forKey: .hangoverMs) ?? 850
        minUtteranceMs = try c.decodeIfPresent(Int.self, forKey: .minUtteranceMs) ?? 300
        bargeInRMSBoost = try c.decodeIfPresent(Float.self, forKey: .bargeInRMSBoost) ?? 3.0
        bargeResumeMs = try c.decodeIfPresent(Int.self, forKey: .bargeResumeMs) ?? 500
        voiceProcessing = try c.decodeIfPresent(Bool.self, forKey: .voiceProcessing) ?? true
    }
}

/// Full pipeline configuration.
public struct VoicePipelineConfig: Sendable {
    public var sttBackend: STTBackend
    /// Kokoro voice name, e.g. "af_heart".
    public var voice: String
    public var vad: VADConfig
    /// Override for the Kokoro models directory; nil uses bundled assets.
    public var kokoroModelsDir: URL?
    /// When set, "stop listening" is intercepted: this line is spoken, then
    /// `.stopListeningCommand`. nil disables (probes, tests).
    public var stopListeningAck: String?
    /// When set, every utterance's transcriber audio + transcript lands here
    /// (UtteranceDump). nil = off, the shipping default.
    public var utteranceDumpDirectory: URL?

    public init(
        sttBackend: STTBackend = .apple,
        voice: String = "af_heart",
        vad: VADConfig = VADConfig(),
        kokoroModelsDir: URL? = nil,
        stopListeningAck: String? = nil,
        utteranceDumpDirectory: URL? = nil
    ) {
        self.sttBackend = sttBackend
        self.voice = voice
        self.vad = vad
        self.kokoroModelsDir = kokoroModelsDir
        self.stopListeningAck = stopListeningAck
        self.utteranceDumpDirectory = utteranceDumpDirectory
    }
}

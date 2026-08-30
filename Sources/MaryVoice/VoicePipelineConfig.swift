//
//  VoicePipelineConfig.swift
//  MaryVoice
//
//  WHAT: Tunable loop knobs. Settings exposes them; the probe can sweep them.
//  IN:   Settings / probe / VoicePipeline.init
//  OUT:  STTBackend / TTSBackend / VADConfig / VoicePipeline
//

import Foundation

/// STT backend. One case today; enum stays so `VoiceTranscriber` can grow.
public enum STTBackend: String, Sendable, Codable, CaseIterable {
    /// Apple Speech — on-device, live partials.
    case apple
}

/// TTS backend the speaker synthesizes with.
public enum TTSBackend: String, Sendable, Codable, CaseIterable {
    /// Kokoro CoreML, on-device.
    case kokoro
    /// Local Seer `/v1/speak` — signed-in session. PIN: all cloud voice goes here.
    case seer

    public var displayName: String {
        switch self {
        case .kokoro: return "Kokoro (on-device)"
        case .seer:   return "Seer (local server)"
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
    /// Audio kept from before speechStart and replayed into STT.
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
        preRollMs: Int = 300,
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

    enum CodingKeys: String, CodingKey {
        case speechStartRMS, speechContinueRMS, hangoverMs, minUtteranceMs,
             preRollMs, bargeInRMSBoost, bargeResumeMs, voiceProcessing
    }

    /// Tolerant decode — persisted in the app config store; new fields must not fail old restores.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speechStartRMS = try c.decodeIfPresent(Float.self, forKey: .speechStartRMS) ?? 0.015
        speechContinueRMS = try c.decodeIfPresent(Float.self, forKey: .speechContinueRMS) ?? 0.008
        hangoverMs = try c.decodeIfPresent(Int.self, forKey: .hangoverMs) ?? 850
        minUtteranceMs = try c.decodeIfPresent(Int.self, forKey: .minUtteranceMs) ?? 300
        preRollMs = try c.decodeIfPresent(Int.self, forKey: .preRollMs) ?? 300
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

    public init(
        sttBackend: STTBackend = .apple,
        voice: String = "af_heart",
        vad: VADConfig = VADConfig(),
        kokoroModelsDir: URL? = nil,
        stopListeningAck: String? = nil
    ) {
        self.sttBackend = sttBackend
        self.voice = voice
        self.vad = vad
        self.kokoroModelsDir = kokoroModelsDir
        self.stopListeningAck = stopListeningAck
    }
}

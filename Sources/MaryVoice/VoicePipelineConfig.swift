//
//  VoicePipelineConfig.swift
//  MaryVoice
//
//  Everything tunable about the loop lives here so Settings can expose it and
//  the probe can sweep it.
//

import Foundation

/// Which speech-to-text backend the pipeline uses.
///
/// ONE CASE, AND IT STAYS AN ENUM. Mary hears through Apple's Speech
/// framework alone — the utterance-final alternative was dropped with its
/// package, and dropping it took a whole dependency graph with it. The type
/// survives because `VoiceTranscriber` is the seam a second backend arrives
/// through, and a config field is cheaper to keep than to reintroduce.
public enum STTBackend: String, Sendable, Codable, CaseIterable {
    /// Apple's Speech framework — on-device, live partial results.
    case apple
}

/// Which text-to-speech backend the speaker synthesizes with.
public enum TTSBackend: String, Sendable, Codable, CaseIterable {
    /// Kokoro CoreML models, fully on-device.
    case kokoro
    /// The local Seer server's /v1/speak proxy — needs a signed-in session.
    ///
    /// EVERY CLOUD VOICE GOES THROUGH HERE. Mary has one hosted engine, so a
    /// second cloud TTS case would be a second API key, a second outage mode
    /// and a second set of transcode assumptions for the same sound.
    case seer

    public var displayName: String {
        switch self {
        case .kokoro: return "Kokoro (on-device)"
        case .seer:   return "Seer (local server)"
        }
    }
}

/// Endpointing thresholds for the energy VAD.
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
    /// While Kokoro speaks, speechStartRMS is multiplied by this so the mic
    /// doesn't trigger on the speaker's own audio. Barge-in must beat it.
    public var bargeInRMSBoost: Float
    /// Quiet time after a provisional barge-in pause before playback resumes
    /// (the interruption was noise, not speech).
    public var bargeResumeMs: Int
    /// Ask the input node for Apple voice processing (echo cancellation) so
    /// full-duplex listening ignores Mary's own speaker output.
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

    /// Tolerant decode: this struct is persisted inside the app's config
    /// store — a newly added field must never fail an old store's restore.
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
    /// Override for the Kokoro models directory; nil uses the bundled assets.
    public var kokoroModelsDir: URL?
    /// When set, an utterance matching "stop listening" is intercepted before
    /// the responder ever sees it: this line is spoken, then
    /// `.stopListeningCommand` is emitted for the app to end the session.
    /// nil disables the intercept entirely (probes, tests).
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

//
//  EnergyVAD.swift
//  MaryVoice
//
//  How the user's voice is analyzed, stage one: energy endpointing. RMS above
//  the start threshold opens an utterance; RMS holding under the (lower)
//  continue threshold for the hangover closes it. Deliberately simple and
//  fully inspectable — the VoiceActivityDetector seam exists so a model-based
//  VAD can replace it without touching the pipeline.
//

import Foundation

public protocol VoiceActivityDetector: AnyObject {
    /// Feed one frame's RMS; returns a verdict for this instant.
    func process(rms: Float, frameDuration: TimeInterval) -> VADVerdict
    var isSpeechActive: Bool { get }
    func reset()
}

public enum VADVerdict: Equatable {
    case none
    case speechStart
    /// Speech ended after `duration` of voiced audio (hangover excluded).
    case speechEnd(duration: TimeInterval)
    /// The burst was shorter than minUtteranceMs — treat as noise.
    case discardedNoise
}

public final class EnergyVAD: VoiceActivityDetector {

    private let config: VADConfig
    /// Multiplies the start threshold (barge-in guard while TTS plays).
    public var thresholdBoost: Float = 1.0

    public private(set) var isSpeechActive = false
    private var voicedDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0

    public init(config: VADConfig) {
        self.config = config
    }

    public func process(rms: Float, frameDuration: TimeInterval) -> VADVerdict {
        let startThreshold = config.speechStartRMS * thresholdBoost
        let continueThreshold = config.speechContinueRMS * thresholdBoost

        if !isSpeechActive {
            if rms >= startThreshold {
                isSpeechActive = true
                voicedDuration = frameDuration
                silenceDuration = 0
                return .speechStart
            }
            return .none
        }

        // Speech active: hysteresis — the (lower) continue threshold keeps
        // an utterance alive through soft syllables.
        if rms >= continueThreshold {
            voicedDuration += frameDuration
            silenceDuration = 0
            return .none
        }

        silenceDuration += frameDuration
        guard silenceDuration >= Double(config.hangoverMs) / 1000 else {
            return .none
        }

        // Utterance closed.
        let duration = voicedDuration
        isSpeechActive = false
        voicedDuration = 0
        silenceDuration = 0

        if duration < Double(config.minUtteranceMs) / 1000 {
            return .discardedNoise
        }
        return .speechEnd(duration: duration)
    }

    public func reset() {
        isSpeechActive = false
        voicedDuration = 0
        silenceDuration = 0
    }
}

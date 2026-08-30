//
//  KokoroSpeechStyle.swift
//  MaryVoice
//
//  WHAT: Expressive voice adjustments + Codable SpeechStyleSelection for Settings.
//  IN:   KokoroEngine.speak / Settings
//  OUT:  TTSSpeechStyle.audioParameters → KokoroAudioProcessor
//

import AVFoundation

// MARK: - TTSSpeechStyle

public struct TTSSpeechStyle: Sendable {

    // MARK: Emotion

    public enum Emotion: Sendable {
        /// Flat baseline — no adjustments.
        case neutral
        /// Upbeat energy: brighter tone, faster pace, slight pitch lift.
        case excited
        /// Relaxed and soothing: warmer tone, gentler highs.
        case calm
        /// Subdued and heavy: darker tone, slower pace, lowered pitch.
        case sad
        /// Direct and confident: forward mid-range, minimal reverb.
        case assertive
        /// Hushed and intimate: very soft highs, extra warmth, close reverb.
        case whisper
    }

    // MARK: Pace

    public enum Pace: Sendable {
        case slow       // ×0.85
        case normal     // ×1.00
        case fast       // ×1.15
        case veryFast   // ×1.30

        var rate: Float {
            switch self {
            case .slow:     return 0.85
            case .normal:   return 1.00
            case .fast:     return 1.15
            case .veryFast: return 1.30
            }
        }
    }

    // MARK: Tone

    public enum Tone: Sendable {
        /// Default — no tonal shift beyond the emotion preset.
        case natural
        /// Extra low-frequency warmth, softer highs.
        case warm
        /// Increased presence and clarity.
        case bright
        /// More bass body, lowered pitch.
        case deep
    }

    // MARK: Stress

    public enum Stress: Sendable {
        /// Soft dynamics, pulled-back delivery.
        case relaxed
        /// Standard delivery.
        case normal
        /// Forward presence — accented, punchy delivery.
        case emphasized
    }

    // MARK: Intonation

    public enum Intonation: Sendable {
        /// Flat, even delivery.
        case monotone
        /// Standard conversational intonation.
        case conversational
        /// Exaggerated rises and falls — narrative / storytelling.
        case expressive
    }

    // MARK: Properties

    public var emotion:    Emotion    = .neutral
    public var pace:       Pace       = .normal
    public var tone:       Tone       = .natural
    public var stress:     Stress     = .normal
    public var intonation: Intonation = .conversational
    /// Pitch shift in semitones. Positive = higher, negative = lower. Range: −12…+12.
    public var pitchShift: Float      = 0

    public init(
        emotion: Emotion = .neutral,
        pace: Pace = .normal,
        tone: Tone = .natural,
        stress: Stress = .normal,
        intonation: Intonation = .conversational,
        pitchShift: Float = 0
    ) {
        self.emotion = emotion
        self.pace = pace
        self.tone = tone
        self.stress = stress
        self.intonation = intonation
        self.pitchShift = pitchShift
    }

    // MARK: Static presets

    public static let neutral = TTSSpeechStyle()

    public static let excited = TTSSpeechStyle(
        emotion:    .excited,
        pace:       .fast,
        tone:       .bright,
        intonation: .expressive,
        pitchShift: 1.5
    )

    public static let calm = TTSSpeechStyle(
        emotion:    .calm,
        pace:       .slow,
        tone:       .warm,
        intonation: .conversational
    )

    /// Casual-conversation register: calm warmth without the slowdown.
    public static let chat = TTSSpeechStyle(
        emotion:    .calm,
        pace:       .normal,
        tone:       .warm,
        intonation: .conversational
    )

    public static let sad = TTSSpeechStyle(
        emotion:    .sad,
        pace:       .slow,
        tone:       .warm,
        stress:     .relaxed,
        pitchShift: -1.5
    )

    public static let assertive = TTSSpeechStyle(
        emotion:    .assertive,
        stress:     .emphasized,
        intonation: .conversational,
        pitchShift: 0.5
    )

    public static let whisper = TTSSpeechStyle(
        emotion:    .whisper,
        pace:       .slow,
        tone:       .warm,
        stress:     .relaxed
    )

    // MARK: Builder API

    public func at(pace: Pace) -> TTSSpeechStyle {
        var s = self; s.pace = pace; return s
    }

    public func with(tone: Tone) -> TTSSpeechStyle {
        var s = self; s.tone = tone; return s
    }

    public func with(stress: Stress) -> TTSSpeechStyle {
        var s = self; s.stress = stress; return s
    }

    public func with(intonation: Intonation) -> TTSSpeechStyle {
        var s = self; s.intonation = intonation; return s
    }

    public func pitched(by semitones: Float) -> TTSSpeechStyle {
        var s = self; s.pitchShift = semitones.clamped(to: -12...12); return s
    }

    /// True when no AVAudioEngine effects are needed — simpler playback path.
    public var isNeutral: Bool {
        emotion == .neutral &&
        pace == .normal &&
        tone == .natural &&
        stress == .normal &&
        intonation == .conversational &&
        pitchShift == 0
    }
}

// MARK: - AudioParameters
// Resolved DSP values used by KokoroAudioProcessor.

extension TTSSpeechStyle {

    struct AudioParameters {
        // EQ (2 bands — high-shelf owned by KokoroDSP biquad, not AVAudioUnitEQ)
        var lowShelfGain: Float  // dB, @ 200 Hz
        var midCutGain:   Float  // dB, @ 3 kHz
        // Dynamics
        var globalGain:   Float  // dB
        // Reverb
        var reverbPreset: AVAudioUnitReverbPreset
        var reverbMix:    Float  // 0–100 %
        // Time/pitch
        var rate:         Float  // playback rate
        var pitch:        Float  // cents (semitones × 100)
    }

    /// Resolves all dimensions into concrete DSP parameters.
    var audioParameters: AudioParameters {
        var lowShelf:   Float
        var midCut:     Float
        var globalGain: Float = 0
        var reverbPreset: AVAudioUnitReverbPreset
        var reverbMix:    Float
        var rate:  Float = pace.rate
        var pitch: Float = pitchShift * 100  // semitones → cents

        // Neutral is transparent — KokoroDSP handles baseline. Styles deviate as needed.
        switch emotion {
        case .neutral:   lowShelf =  0.0; midCut =  0.0; reverbPreset = .smallRoom;  reverbMix =  0
        case .excited:   lowShelf =  0.5; midCut =  0.5; reverbPreset = .smallRoom;  reverbMix =  6
        case .calm:      lowShelf =  1.5; midCut = -1.0; reverbPreset = .mediumRoom; reverbMix = 12
        case .sad:       lowShelf =  2.0; midCut = -1.5; reverbPreset = .mediumRoom; reverbMix = 15
        case .assertive: lowShelf =  0.5; midCut =  0.5; reverbPreset = .smallRoom;  reverbMix =  4
        case .whisper:   lowShelf =  2.5; midCut =  0.0; reverbPreset = .smallRoom;  reverbMix = 18
        }

        switch tone {
        case .natural: break
        case .warm:    lowShelf += 1.0
        case .bright:  midCut   += 1.0
        case .deep:    lowShelf += 1.5; pitch -= 200  // extra -2 semitones
        }

        switch stress {
        case .relaxed:    globalGain -= 1.0
        case .normal:     break
        case .emphasized: midCut += 1.0; globalGain += 0.5
        }

        switch intonation {
        case .monotone:       rate *= 0.97
        case .conversational: break
        case .expressive:     rate *= 1.03
        }

        return AudioParameters(
            lowShelfGain: lowShelf.clamped(to: -6...6),
            midCutGain:   midCut.clamped(to: -6...3),
            globalGain:   globalGain,
            reverbPreset: reverbPreset,
            reverbMix:    reverbMix.clamped(to: 0...60),
            rate:         rate.clamped(to: 0.5...2.0),
            pitch:        pitch.clamped(to: -1200...1200)
        )
    }
}

// MARK: - SpeechStyleSelection

/// Codable preset wrapper so Settings can persist a choice.
public enum SpeechStyleSelection: String, Sendable, Codable, CaseIterable {
    /// Match the moment: chat for conversation, neutral for tasks.
    case auto
    case neutral, excited, calm, sad, assertive, whisper

    public var style: TTSSpeechStyle {
        switch self {
        case .auto:      return .chat
        case .neutral:   return .neutral
        case .excited:   return .excited
        case .calm:      return .calm
        case .sad:       return .sad
        case .assertive: return .assertive
        case .whisper:   return .whisper
        }
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto — match the moment"
        default: return rawValue.capitalized
        }
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

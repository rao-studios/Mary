//
//  BargeInGovernor.swift
//  MaryVoice
//
//  The interruption cadence while Mary speaks, as a pure state machine so
//  the timing logic is testable without audio. Three phases:
//
//    idle ──rms ≥ onset──▶ provisional (playback pauses IMMEDIATELY)
//    provisional ──voiced ≥ commitAfter──▶ commit (full barge-in)
//    provisional ──quiet ≥ retreatAfter──▶ retreat (resume playback)
//
//  A cough costs a sub-second dip in playback; real speech stops Mary and
//  becomes the next utterance.
//

import Foundation

struct BargeInGovernor {

    enum Action: Equatable {
        case none
        /// First frame over the onset threshold — pause playback NOW.
        case pause
        /// Sustained speech — commit the barge-in (hard stop, new utterance).
        case commit
        /// The interruption died out — resume playback.
        case resume
    }

    private(set) var isProvisional = false
    private var voicedDuration: TimeInterval = 0
    private var quietDuration: TimeInterval = 0

    let onsetRMS: Float
    let commitAfter: TimeInterval
    let retreatAfter: TimeInterval

    init(onsetRMS: Float, commitAfter: TimeInterval, retreatAfter: TimeInterval) {
        self.onsetRMS = onsetRMS
        self.commitAfter = commitAfter
        self.retreatAfter = retreatAfter
    }

    mutating func process(rms: Float, frameDuration: TimeInterval) -> Action {
        if !isProvisional {
            guard rms >= onsetRMS else { return .none }
            isProvisional = true
            voicedDuration = frameDuration
            quietDuration = 0
            return .pause
        }
        if rms >= onsetRMS {
            voicedDuration += frameDuration
            quietDuration = 0
        } else {
            quietDuration += frameDuration
        }
        if voicedDuration >= commitAfter {
            reset()
            return .commit
        }
        if quietDuration >= retreatAfter {
            reset()
            return .resume
        }
        return .none
    }

    mutating func reset() {
        isProvisional = false
        voicedDuration = 0
        quietDuration = 0
    }
}

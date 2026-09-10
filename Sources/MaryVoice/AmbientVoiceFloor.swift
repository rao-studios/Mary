//
//  AmbientVoiceFloor.swift
//  MaryVoice
//
//  WHAT: Pure rule for when an unprompted line may take the floor.
//  IN:   VoicePipeline.speakAmbientUtterance / text-mode FollowUpSpeech
//  OUT:  speakNow | waitForQuiet | drop
//  PIN:  Shorter than follow-up's 15s — a late remark is a non-sequitur.
//

import Foundation

public enum AmbientVoiceFloor {

    /// How long an unprompted line may wait for a quiet room.
    public static let quietBudget: TimeInterval = 5

    /// Hold poll interval. Matches FollowUpSpeech / playFollowUpWhenQuiet.
    public static let pollInterval: TimeInterval = 0.2

    public static var pollNanoseconds: UInt64 {
        UInt64(pollInterval * 1_000_000_000)
    }

    public enum Verdict: Equatable {
        /// Floor is clear; speak.
        case speakNow
        /// Busy, still within budget — hold and ask again.
        case waitForQuiet
        /// Busy, out of budget. The moment has passed.
        case drop
    }

    /// Pure (clear, waited) → verdict. PIN: a busy room is never a cut.
    public static func verdict(
        floorIsClear: Bool,
        waited: TimeInterval,
        budget: TimeInterval = AmbientVoiceFloor.quietBudget
    ) -> Verdict {
        if floorIsClear { return .speakNow }
        return waited >= budget ? .drop : .waitForQuiet
    }
}

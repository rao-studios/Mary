//
//  AmbientVoiceFloor.swift
//  MaryVoice
//
//  WHEN AN UNPROMPTED LINE MAY TAKE THE FLOOR — the pure rule, so the voice
//  pipeline and text mode's `FollowUpSpeech` name ONE constant instead of two
//  literals kept equal by comment.
//
//  That is not hypothetical tidiness: `VoicePipeline.playFollowUpWhenQuiet`'s
//  15 s and `FollowUpFloor.quietBudget` are already two separate literals held
//  in agreement by a comment on each. A third pair would be a third chance to
//  drift, on the one path where drifting means one mode speaks and the other
//  silently does not.
//
//  DELIBERATELY SHORTER THAN THE FOLLOW-UP'S 15 s. A follow-up is an ANSWER,
//  and a late answer is still an answer. An unprompted remark is about the
//  PRESENT, and one delivered fifteen seconds after the moment it describes is
//  a non-sequitur — so dropping it is the correct outcome rather than a
//  failure. Five is a starting number, not a measured one; the trace is built
//  to settle it. A session full of `droppedStale` with no `spoke` means the
//  room is never quiet, which is a different finding from a bad floor.
//

import Foundation

public enum AmbientVoiceFloor {

    /// How long an unprompted line may wait for a quiet room before the moment
    /// has passed.
    public static let quietBudget: TimeInterval = 5

    /// How often the hold re-asks. Matches `FollowUpSpeech.pollInterval` and
    /// `playFollowUpWhenQuiet` for the same reason both chose it: a line
    /// should land IN the pause, not half a second after it.
    public static let pollInterval: TimeInterval = 0.2

    public static var pollNanoseconds: UInt64 {
        UInt64(pollInterval * 1_000_000_000)
    }

    public enum Verdict: Equatable {
        /// The floor is clear; speak.
        case speakNow
        /// Busy, still within budget — hold and ask again.
        case waitForQuiet
        /// Busy, out of budget. The moment has passed.
        case drop
    }

    /// The whole rule, as a pure function over (clear, waited) so it is
    /// testable without a speaker, a brain or a clock — the discipline
    /// `FollowUpFloor.verdict` already keeps.
    ///
    /// NOTE THE ASYMMETRY WITH `FollowUpFloor`, and that it is deliberate:
    /// there, a non-stale follow-up returns `.speakNow` into a BUSY room,
    /// because it belongs to the exchange on screen and has earned the cut.
    /// Nothing here may ever cut. An unprompted remark outranks nothing at
    /// all, so a busy room can only ever be waited out.
    public static func verdict(
        floorIsClear: Bool,
        waited: TimeInterval,
        budget: TimeInterval = AmbientVoiceFloor.quietBudget
    ) -> Verdict {
        if floorIsClear { return .speakNow }
        return waited >= budget ? .drop : .waitForQuiet
    }
}

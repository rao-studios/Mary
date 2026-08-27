//
//  AmbientVoiceDelivery.swift
//  MaryFoundation
//
//  WHAT HAPPENED AT THE EAR to a line Mary volunteered — the second half of
//  an AmbientVoice trace row, and the half nobody else can answer.
//
//  IT LIVES HERE BECAUSE OF THE LAYERING, not by preference. The engine that
//  DECIDES to speak is in MaryAmbient; the arm that finally learns whether
//  the line reached a room is `VoicePipeline` in MaryVoice. Those two
//  packages cannot see each other — MaryAmbient depends on MaryFoundation and
//  the system frameworks and nothing else, deliberately — so the vocabulary
//  they must agree on belongs to the one package both of them already import.
//  `AbilitySkillReference` crosses the identical seam for the identical
//  reason.
//
//  KEPT SEPARATE FROM THE ENGINE'S OWN VERDICT, and that split is the whole
//  diagnostic value of the trace. "Recorded but never emitted" and "emitted
//  but never heard" are different failures with different fixes: the first
//  says the scorer is wrong, the second says the quiet-room gate is. One enum
//  spanning both would collapse them into a single number and the tuning loop
//  would have nothing to read.
//

import Foundation

/// WHAT HAPPENED AT THE EAR. Written LATE — by whichever arm actually decided
/// — onto a candidate row the engine booked earlier.
public enum AmbientVoiceDelivery: String, Codable, Hashable, Sendable, CaseIterable {
    /// It reached the ear.
    case spoke
    /// The room was busy; the line is waiting for a pause.
    case heldForQuiet
    /// The budget expired with the room still busy. An unprompted remark is
    /// about the present, so a late one is a non-sequitur rather than a late
    /// answer — dropping it is the correct outcome, not a failure.
    case droppedStale
    /// The user took the floor while it was speaking or waiting. Ambient
    /// speech always yields; this is also the engine's one negative signal.
    case preemptedByUser
    /// `observe` mode: it would have spoken, and it did not. The dry run.
    case silencedByMode
    /// The engine decided, and nothing could write the sentence — no model
    /// installed, or composition came back empty.
    ///
    /// ITS OWN CASE RATHER THAN `droppedStale`, because the fix is different:
    /// stale means the room was never quiet, this means the voice was never
    /// there. A run full of these is a wiring problem, not a floor problem,
    /// and collapsing them would hide that.
    case couldNotCompose
    /// The voice session went idle underneath it.
    case sessionEnded

    public var displayName: String {
        switch self {
        case .spoke:           return "spoke"
        case .heldForQuiet:    return "held for quiet"
        case .droppedStale:    return "dropped — the moment passed"
        case .preemptedByUser: return "you took the floor"
        case .silencedByMode:  return "silenced — observing"
        case .couldNotCompose: return "no voice to say it with"
        case .sessionEnded:    return "session ended"
        }
    }

    /// Did this actually reach the ear? Named ONCE so a pane, a report, a rate
    /// limiter and a test cannot disagree about what counts as having spoken —
    /// the discipline `ReadRoute.reachedVoice` already keeps for reads. The
    /// rate limiter in particular must not be reset by a line nobody heard.
    public var reachedEar: Bool { self == .spoke }
}

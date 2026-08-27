//
//  FollowUpPriority.swift
//  MaryVoice
//
//  Pure decision table for what a newly-arrived follow-up token does to the
//  floor right now, given where the turn is. Same shape as AmendPlanner's
//  decision table and AmbientVoiceFloor's verdict — this one just wasn't
//  named as one before this extraction; it was inlined in handleProactive.
//

import Foundation

enum FollowUpPriority {

    enum Directive: Equatable {
        /// The room is quiet — stream the follow-up live right now.
        case streamNow
        /// A deeper answer is mid-generation and this follow-up outranks it —
        /// cancel it barge-in-style, then stream.
        case preemptThenStream
        /// Generation is done, audio is still draining — yield at the
        /// sentence boundary, then stream.
        case yieldThenStream
        /// The user (or a newer turn) has the floor — buffer for later.
        case buffer
    }

    static func directive(
        state: VoicePipelineState,
        generationActive: Bool,
        isStale: Bool
    ) -> Directive {
        switch (state, generationActive) {
        case (.listening(utteranceActive: false), _):
            return .streamNow
        case (_, true) where !isStale:
            return .preemptThenStream
        case (.speaking, false) where !isStale:
            return .yieldThenStream
        default:
            return .buffer
        }
    }

    /// Is this follow-up narrating an exchange the user has already moved
    /// past? A STANDALONE notice (nil origin — the coding bridge's "that
    /// change didn't go through") belongs to no exchange and can never be
    /// stale; it keeps its urgency. Before any turn has begun there is
    /// nothing to be stale against.
    static func isStale(origin: UUID?, currentUserTurnID: UUID?) -> Bool {
        guard let origin, let currentUserTurnID else { return false }
        return origin != currentUserTurnID
    }
}

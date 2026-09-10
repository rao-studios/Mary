//
//  FollowUpPriority.swift
//  MaryVoice
//
//  WHAT: Decision table for a newly arrived follow-up token vs the floor.
//  IN:   VoicePipeline.handleProactive
//  OUT:  streamNow | preemptThenStream | yieldThenStream | buffer
//
//  Sibling of AmendPlanner / AmbientVoiceFloor (pure verdict, no actor).
//

import Foundation

enum FollowUpPriority {

    enum Directive: Equatable {
        /// Quiet room — stream now.
        case streamNow
        /// Deeper answer mid-generation — cancel barge-in-style, then stream.
        case preemptThenStream
        /// Generation done, audio draining — yield at sentence boundary, then stream.
        case yieldThenStream
        /// User or a newer turn has the floor — buffer.
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

    /// Follow-up narrating an exchange the user has moved past?
    /// Nil origin (standalone notice) is never stale.
    static func isStale(origin: UUID?, currentUserTurnID: UUID?) -> Bool {
        guard let origin, let currentUserTurnID else { return false }
        return origin != currentUserTurnID
    }
}

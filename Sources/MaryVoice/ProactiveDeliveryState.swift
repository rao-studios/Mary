//
//  ProactiveDeliveryState.swift
//  MaryVoice
//
//  WHAT: Shared state for follow-up, canned ack, progress, ambient speech.
//  IN:   VoicePipeline+ProactivePlayback
//  OUT:  buffer / origin / lease / ambientCandidateID
//

import Foundation

struct ProactiveDeliveryState {
    private(set) var followUpBuffer = ""
    /// Whose passage the buffer holds. Nil = standalone notice (never stale).
    private(set) var followUpBufferOrigin: UUID?
    /// True once follow-up audio began streaming.
    private(set) var followUpSpeaking = false
    /// Follow-up's own physical writer — not the turn's lease after a preemption.
    private(set) var followUpSpeakerLease: UUID?
    /// Tokens arriving mid-cut keep buffering and speak after the cut lands.
    var followUpCutInProgress = false
    /// Candidate currently speaking, if the floor is an unprompted remark.
    var ambientCandidateID: UUID?

    mutating func appendFollowUpToken(_ token: String, origin: UUID?) {
        if followUpBuffer.isEmpty { followUpBufferOrigin = origin }
        followUpBuffer += token
    }

    mutating func replaceFollowUpBuffer(_ text: String, origin: UUID?) {
        guard !text.isEmpty else { return }
        followUpBuffer = text
        followUpBufferOrigin = origin
    }

    /// Buffer and origin move together.
    mutating func clearFollowUpBuffer() {
        followUpBuffer = ""
        followUpBufferOrigin = nil
    }

    /// Clear only if `text` is still exactly what's buffered (token may arrive mid-feed).
    mutating func clearFollowUpBufferIfUnchanged(from text: String) {
        guard followUpBuffer == text else { return }
        clearFollowUpBuffer()
    }

    mutating func markSpeaking(lease: UUID) {
        followUpSpeaking = true
        followUpSpeakerLease = lease
    }

    mutating func markStopped() {
        followUpSpeaking = false
        followUpSpeakerLease = nil
    }

    /// Clear speaking/lease only if `lease` is still active.
    mutating func clearSpeaking(ifLeaseIs lease: UUID) {
        guard followUpSpeakerLease == lease else { return }
        markStopped()
    }

    /// Shared reset for `stop()` and `performStopListening()`. Does not touch
    /// `ambientCandidateID` — that is `stop()`-specific (stale across sessions).
    mutating func forceStop() {
        clearFollowUpBuffer()
        followUpSpeaking = false
        followUpSpeakerLease = nil
        followUpCutInProgress = false
    }
}

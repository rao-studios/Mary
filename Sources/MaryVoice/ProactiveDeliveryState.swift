//
//  ProactiveDeliveryState.swift
//  MaryVoice
//
//  State four different kinds of proactive speech share — follow-up
//  narration, a canned acknowledgement, a routine's progress line, an
//  ambient utterance: what's buffered, whose it is, and whether the
//  proactive lane currently owns the floor.
//

import Foundation

struct ProactiveDeliveryState {
    private(set) var followUpBuffer = ""
    /// WHOSE passage the buffer holds. A follow-up narrates the exchange that
    /// spawned its routine; nil marks a STANDALONE notice (coding bridge): it
    /// belongs to no exchange, so it can never be stale.
    private(set) var followUpBufferOrigin: UUID?
    /// True once follow-up audio began streaming into the speaker.
    private(set) var followUpSpeaking = false
    /// Follow-ups are their own physical speaker writer. It is not the same
    /// as the turn's own floor lease once one preempts a still-streaming
    /// reply.
    private(set) var followUpSpeakerLease: UUID?
    /// Guards actor reentrancy while a preemption cut is in flight — tokens
    /// arriving mid-cut keep buffering and speak after the cut lands.
    var followUpCutInProgress = false
    /// THE CANDIDATE CURRENTLY SPEAKING, if the thing on the floor is an
    /// unprompted remark rather than a turn or a routine's follow-up.
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

    /// The buffer and WHOSE it is move together — a buffer without its origin
    /// is the origin-blind state this pairing exists to avoid.
    mutating func clearFollowUpBuffer() {
        followUpBuffer = ""
        followUpBufferOrigin = nil
    }

    /// Only clears if `text` is still exactly what's buffered — a streaming
    /// token may arrive while a `feed` call suspends; this must never erase
    /// the next line's accumulation.
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

    /// Clears speaking/lease only if `lease` is still the active one — a
    /// newer follow-up may already have installed its own lease while the
    /// caller's `await` was suspended.
    mutating func clearSpeaking(ifLeaseIs lease: UUID) {
        guard followUpSpeakerLease == lease else { return }
        markStopped()
    }

    /// The shared reset `stop()` and `performStopListening()` both perform:
    /// buffer, speaking flag, lease, and the cut-in-progress guard. Does NOT
    /// touch `ambientCandidateID` — that one is stop()-specific (a stale
    /// marker across sessions would make the next session's first barge-in
    /// look like it interrupted a remark that ended long ago), so it's left
    /// to callers to clear on its own.
    mutating func forceStop() {
        clearFollowUpBuffer()
        followUpSpeaking = false
        followUpSpeakerLease = nil
        followUpCutInProgress = false
    }
}

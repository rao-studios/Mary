//
//  FollowUpPriorityTests.swift
//  MaryVoiceTests
//
//  The follow-up-token decision table: stream into a quiet room, preempt a
//  live turn only when fresh, yield at the drain boundary, otherwise buffer.
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct FollowUpPriorityTests {

    @Test func quietRoomAlwaysStreamsEvenWhenStale() {
        #expect(FollowUpPriority.directive(
            state: .listening(utteranceActive: false), generationActive: false, isStale: true) == .streamNow)
        #expect(FollowUpPriority.directive(
            state: .listening(utteranceActive: false), generationActive: true, isStale: false) == .streamNow)
    }

    @Test func freshGenerationIsPreempted() {
        #expect(FollowUpPriority.directive(
            state: .thinking, generationActive: true, isStale: false) == .preemptThenStream)
        #expect(FollowUpPriority.directive(
            state: .speaking, generationActive: true, isStale: false) == .preemptThenStream)
    }

    @Test func staleGenerationIsNeverPreempted() {
        #expect(FollowUpPriority.directive(
            state: .thinking, generationActive: true, isStale: true) == .buffer)
    }

    @Test func drainingFreshReplyYields() {
        #expect(FollowUpPriority.directive(
            state: .speaking, generationActive: false, isStale: false) == .yieldThenStream)
    }

    @Test func staleDrainIsBuffered() {
        #expect(FollowUpPriority.directive(
            state: .speaking, generationActive: false, isStale: true) == .buffer)
    }

    @Test func userMidUtteranceWithNoGenerationIsBuffered() {
        #expect(FollowUpPriority.directive(
            state: .listening(utteranceActive: true), generationActive: false, isStale: false) == .buffer)
        #expect(FollowUpPriority.directive(
            state: .transcribing, generationActive: false, isStale: false) == .buffer)
    }

    @Test func generationActiveOutranksTheUserMidUtteranceWhenFresh() {
        // Matches the pre-extraction inline switch verbatim: `(_, true)`
        // preempts regardless of state (other than the explicit quiet-room
        // case above it) as long as the follow-up isn't stale — a background
        // generation racing a new voice utterance is not exempted.
        #expect(FollowUpPriority.directive(
            state: .transcribing, generationActive: true, isStale: false) == .preemptThenStream)
    }

    @Test func staleness() {
        let a = UUID()
        let b = UUID()
        #expect(FollowUpPriority.isStale(origin: a, currentUserTurnID: b))
        #expect(!FollowUpPriority.isStale(origin: a, currentUserTurnID: a))
        // A standalone notice (nil origin) is never stale.
        #expect(!FollowUpPriority.isStale(origin: nil, currentUserTurnID: a))
        // Nothing to be stale against before any turn has begun.
        #expect(!FollowUpPriority.isStale(origin: a, currentUserTurnID: nil))
    }
}

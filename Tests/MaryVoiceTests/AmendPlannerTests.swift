//
//  AmendPlannerTests.swift
//  MaryVoiceTests
//
//  WHAT: Thinking-phase interrupt — capture-first, cancel-late, never on silence.
//  OUT:  AmendPlanner
//

import Testing
@testable import MaryVoice

@Suite struct AmendPlannerTests {

    @Test func silenceNeverDisturbs() {
        #expect(AmendPlanner.directive(
            for: .none, capturing: false, isTranscribing: false, pendingCommit: false) == .none)
    }

    @Test func onsetBeginsSilentCapture() {
        #expect(AmendPlanner.directive(
            for: .pause, capturing: false, isTranscribing: false, pendingCommit: false) == .beginCapture)
    }

    @Test func provisionalFramesKeepCapturing() {
        #expect(AmendPlanner.directive(
            for: .none, capturing: true, isTranscribing: false, pendingCommit: false) == .captureFrame)
    }

    @Test func noiseDiscardsWithoutTouchingTheTurn() {
        #expect(AmendPlanner.directive(
            for: .resume, capturing: true, isTranscribing: false, pendingCommit: false) == .discard)
        // Retreat without a capture (stale governor echo) is a no-op.
        #expect(AmendPlanner.directive(
            for: .resume, capturing: false, isTranscribing: false, pendingCommit: false) == .none)
    }

    @Test func commitSupersedesDuringThinking() {
        #expect(AmendPlanner.directive(
            for: .commit, capturing: true, isTranscribing: false, pendingCommit: false) == .commitNow)
    }

    @Test func commitDefersDuringTranscribing() {
        #expect(AmendPlanner.directive(
            for: .commit, capturing: true, isTranscribing: true, pendingCommit: false) == .deferCommit)
    }

    @Test func pendingCommitCapturesEverything() {
        for action: BargeInGovernor.Action in [.none, .pause, .commit, .resume] {
            #expect(AmendPlanner.directive(
                for: action, capturing: true, isTranscribing: true, pendingCommit: true) == .captureFrame)
        }
    }
}

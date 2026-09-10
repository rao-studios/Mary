//
//  VoiceFloorOwnerTests.swift
//  MaryVoiceTests
//
//  WHAT: Shared speaker voice-floor fence / claim / replace.
//  OUT:  VoiceFloorOwner
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct VoiceFloorOwnerTests {

    private static func makeOwner() -> (VoiceFloorOwner, RecordingResponder) {
        let speaker = KokoroStreamSpeaker(synthesizer: OwnerNullSynthesizer())
        let responder = RecordingResponder()
        return (VoiceFloorOwner(speaker: speaker, responder: responder), responder)
    }

    @Test func claimReturnsALeaseAndBecomesCurrent() async {
        let (owner, _) = Self.makeOwner()
        let lease = await owner.claim()
        #expect(lease != nil)
        #expect(owner.currentLease == lease)
    }

    @Test func replaceFailsWhenExpectationIsStale() async {
        let (owner, _) = Self.makeOwner()
        _ = await owner.claim()
        // A stale expectation (nil, or any lease that isn't current) must be
        // refused — an old detached task cannot retake the floor.
        #expect(await owner.replace(expecting: nil) == nil)
        #expect(await owner.replace(expecting: UUID()) == nil)
    }

    @Test func replaceSucceedsAndInstallsAFreshLease() async {
        let (owner, _) = Self.makeOwner()
        let original = await owner.claim()
        let replaced = await owner.replace(expecting: original)
        #expect(replaced != nil)
        #expect(replaced != original)
        #expect(owner.currentLease == replaced)
    }

    @Test func markTerminatedStopsAllFutureClaims() async {
        let (owner, _) = Self.makeOwner()
        let first = await owner.claim()
        owner.markTerminated()
        #expect(await owner.claim() == nil)
        #expect(await owner.replace(expecting: first) == nil)
    }

    @Test func hardStopAndReleaseClearsTheLeaseOnlyWhenItMatches() async {
        let (owner, _) = Self.makeOwner()
        let lease = await owner.claim()!
        // A stale lease is refused — the floor may already belong to someone
        // else by the time this call lands.
        #expect(await owner.hardStopAndRelease(expecting: UUID()) == false)
        #expect(owner.currentLease == lease)
        #expect(await owner.hardStopAndRelease(expecting: lease) == true)
        #expect(owner.currentLease == nil)
    }

    @Test func releaseUnconditionallyAlwaysClearsTheLease() async {
        let (owner, _) = Self.makeOwner()
        _ = await owner.claim()
        await owner.releaseUnconditionally()
        #expect(owner.currentLease == nil)
    }

    @Test func cancelResponderReachesTheSharedResponder() async {
        let (owner, responder) = Self.makeOwner()
        await owner.cancelResponder()
        #expect(responder.cancelCount == 1)
    }

    @Test func ownershipFencesResolveImmediatelyWithNothingInFlight() async {
        // No begin() ever ran against these fences, so waiting must not hang.
        let (owner, _) = Self.makeOwner()
        await owner.waitForOwnershipOperations()
        await owner.waitForResponderCancellations()
    }
}

private actor OwnerNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

private final class RecordingResponder: LanguageResponder, @unchecked Sendable {
    private(set) var cancelCount = 0

    func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancel() async {
        cancelCount += 1
    }
}

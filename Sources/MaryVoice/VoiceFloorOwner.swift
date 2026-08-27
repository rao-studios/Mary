//
//  VoiceFloorOwner.swift
//  MaryVoice
//
//  Who currently owns the shared KokoroStreamSpeaker's voice floor, and the
//  async fencing VoicePipeline.stop() needs: claim/replace/cancel calls cross
//  an actor boundary and can suspend, so teardown must wait for any in-flight
//  one to settle before the unconditional release — otherwise a claim that
//  wins the race after "stop" already ran would leave the floor claimed by a
//  session nobody is listening to anymore.
//

import Foundation

/// Counts in-flight async operations against a shared cross-actor resource and
/// lets teardown wait for the count to reach zero before an unconditional
/// release. VoicePipeline needed this exact shape twice — once for the
/// speaker's voice floor, once for the shared responder's cancellation —
/// factored here so the two copies can't drift out of agreement.
struct AsyncOperationFence {
    private var operations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    mutating func begin() {
        operations += 1
    }

    mutating func end() {
        precondition(operations > 0)
        operations -= 1
        guard operations == 0 else { return }
        let resuming = waiters
        waiters = []
        for waiter in resuming { waiter.resume() }
    }

    mutating func wait() async {
        guard operations > 0 else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Owns the physical voice-floor lease on the shared `KokoroStreamSpeaker` and
/// the shared `LanguageResponder`'s cancellation, on VoicePipeline's behalf.
///
/// A plain reference type, not a second actor: every method here is only ever
/// called from VoicePipeline's own isolated context, so wrapping the existing
/// cross-actor `await speaker...`/`await responder...` calls adds no new
/// suspension point beyond what already exists inline. A second actor would
/// add one, for no independent invariant gained.
final class VoiceFloorOwner {
    private let speaker: KokoroStreamSpeaker
    private let responder: any LanguageResponder

    private(set) var currentLease: UUID?
    private var ownershipFence = AsyncOperationFence()
    private var cancellationFence = AsyncOperationFence()
    private var watchTask: Task<Void, Never>?
    private var watchLease: UUID?

    /// Mirrors VoicePipeline.terminated. Set via `markTerminated()` in the
    /// same synchronous statement run that sets the pipeline's own flag (no
    /// `await` between the two), so the two can never observably disagree.
    private var terminated = false

    init(speaker: KokoroStreamSpeaker, responder: any LanguageResponder) {
        self.speaker = speaker
        self.responder = responder
    }

    func markTerminated() {
        terminated = true
    }

    /// Claim a fresh voice writer. Claiming the floor is the one operation
    /// that may hard-stop the shared speaker; all subsequent feed/flush/
    /// remote operations are conditional on the returned id.
    @discardableResult
    func claim(hardStop: Bool = true) async -> UUID? {
        guard !terminated else { return nil }
        ownershipFence.begin()
        defer { ownershipFence.end() }
        let lease = UUID()
        _ = await speaker.claimVoiceFloor(lease, hardStop: hardStop)
        // Teardown may have entered while the speaker actor was busy. It waits
        // for this operation before releasing the floor, so leaving the lease
        // installed here is safe and lets that one release retire it.
        guard !terminated else { return nil }
        currentLease = lease
        return lease
    }

    /// Transfer a live voice session from the current reply to a proactive
    /// line. Unlike a new utterance, this is not an unconditional claim: an
    /// old detached task must not retake the speaker after a newer utterance
    /// has installed a different lease while this actor was suspended.
    func replace(expecting expectedLease: UUID?) async -> UUID? {
        guard !terminated, let expectedLease, currentLease == expectedLease else {
            return nil
        }
        ownershipFence.begin()
        defer { ownershipFence.end() }
        let lease = UUID()
        guard await speaker.replaceVoiceFloor(lease, replacing: expectedLease),
              !terminated, currentLease == expectedLease
        else { return nil }
        currentLease = lease
        return lease
    }

    func waitForOwnershipOperations() async {
        await ownershipFence.wait()
    }

    /// The claim→hard-stop→release core `commitAmend` and `performBargeIn`
    /// share: a hard stop that only takes effect if this is still the current
    /// lease, clearing the lease on success.
    @discardableResult
    func hardStopAndRelease(expecting lease: UUID) async -> Bool {
        guard await speaker.hardStop(lease: lease), !terminated, currentLease == lease else {
            return false
        }
        currentLease = nil
        return true
    }

    /// The unconditional release `stop()` performs once every outstanding
    /// ownership operation above has settled.
    func releaseUnconditionally() async {
        currentLease = nil
        await speaker.leaveVoiceFloor()
    }

    /// Abandon a lease this call itself just claimed, when a later step
    /// (opening the mic) failed before the session could really begin.
    func abandon(_ lease: UUID) async {
        currentLease = nil
        _ = await speaker.leaveVoiceFloor(lease: lease)
    }

    func cancelResponder() async {
        cancellationFence.begin()
        defer { cancellationFence.end() }
        await responder.cancel()
    }

    func waitForResponderCancellations() async {
        await cancellationFence.wait()
    }

    func stopWatch(for lease: UUID? = nil) {
        guard lease == nil || watchLease == lease else { return }
        watchTask?.cancel()
        watchTask = nil
        watchLease = nil
    }

    /// `submitTurn`'s shape: await speaker.events() inline, THEN re-check the
    /// lease is still current, THEN start the forwarding task. Kept distinct
    /// from `startWatch` deliberately — the two have different re-check
    /// timing, and unifying them would be a behavior change this extraction
    /// isn't asking for.
    @discardableResult
    func watchInline(
        expecting lease: UUID,
        onEvent: @escaping @Sendable (SpeakerEvent) async -> Void
    ) async -> Bool {
        stopWatch()
        let speakerEvents = await speaker.events()
        guard currentLease == lease else { return false }
        watchTask = Task {
            for await event in speakerEvents {
                if Task.isCancelled { break }
                await onEvent(event)
            }
        }
        watchLease = lease
        return true
    }

    /// `startFollowUpSpeakerWatch`'s shape: the task starts immediately; the
    /// `await speaker.events()` happens inside it, not before it starts.
    func startWatch(lease: UUID, onEvent: @escaping @Sendable (SpeakerEvent) async -> Void) {
        guard watchTask == nil else { return }
        let speaker = self.speaker
        let task = Task {
            let speakerEvents = await speaker.events()
            for await event in speakerEvents {
                if Task.isCancelled { break }
                await onEvent(event)
            }
        }
        watchTask = task
        watchLease = lease
    }
}

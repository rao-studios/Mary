//
//  VoiceFloorOwner.swift
//  MaryVoice
//
//  WHAT: Lease + fences on the shared speaker floor and responder cancel.
//  IN:   VoicePipeline (same isolated context) → this
//  OUT:  KokoroStreamSpeaker / LanguageResponder
//  PIN:  Not a second actor — wrapping existing awaits adds no extra hop.
//

import Foundation

/// Counts in-flight cross-actor ops; teardown waits for zero before release.
/// Used twice: speaker floor and responder cancel.
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

/// Physical voice-floor lease on `KokoroStreamSpeaker` plus responder cancel,
/// on VoicePipeline's behalf. Plain class — called only from that actor.
final class VoiceFloorOwner {
    private let speaker: KokoroStreamSpeaker
    private let responder: any LanguageResponder

    private(set) var currentLease: UUID?
    private var ownershipFence = AsyncOperationFence()
    private var cancellationFence = AsyncOperationFence()
    private var watchTask: Task<Void, Never>?
    private var watchLease: UUID?

    /// Mirrors VoicePipeline.terminated. Set in the same sync run (no await).
    private var terminated = false

    init(speaker: KokoroStreamSpeaker, responder: any LanguageResponder) {
        self.speaker = speaker
        self.responder = responder
    }

    func markTerminated() {
        terminated = true
    }

    /// Claim a fresh writer. The one op that may hard-stop; later feed/flush
    /// are conditional on the returned id.
    @discardableResult
    func claim(hardStop: Bool = true) async -> UUID? {
        guard !terminated else { return nil }
        ownershipFence.begin()
        defer { ownershipFence.end() }
        let lease = UUID()
        _ = await speaker.claimVoiceFloor(lease, hardStop: hardStop)
        // Teardown waits for this op; leave the lease for that one release.
        guard !terminated else { return nil }
        currentLease = lease
        return lease
    }

    /// Transfer the floor to a proactive line. CAS: an old task must not retake a newer lease.
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

    /// Claim→hard-stop→release shared by `commitAmend` and `performBargeIn`.
    @discardableResult
    func hardStopAndRelease(expecting lease: UUID) async -> Bool {
        guard await speaker.hardStop(lease: lease), !terminated, currentLease == lease else {
            return false
        }
        currentLease = nil
        return true
    }

    /// Unconditional release `stop()` performs once outstanding ops have settled.
    func releaseUnconditionally() async {
        currentLease = nil
        await speaker.leaveVoiceFloor()
    }

    /// Drop a lease this call just claimed, when a later step (opening the mic) failed.
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

    /// `submitTurn` shape: await events inline, then re-check lease, then forward.
    /// Distinct from `startWatch` (different re-check timing).
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

    /// `startFollowUpSpeakerWatch` shape: task starts immediately; events await inside it.
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

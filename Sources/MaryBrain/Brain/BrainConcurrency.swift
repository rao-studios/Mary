//
//  BrainConcurrency.swift
//  MaryBrain
//
//  WHAT: Lock-based concurrency primitives.
//  IN:   MaryBrain.swift
//  OUT:  ProactiveMulticast, LaneEmitter, TurnBox, AsyncGate
//
import MaryVoice
import Foundation

/// Synchronous, lock-guarded turn registration. Two jobs: 1.
final class ProactiveMulticast: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ProactiveEvent>.Continuation] = [:]

    func subscribe() -> AsyncStream<ProactiveEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ProactiveEvent>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    func yield(_ event: ProactiveEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }
}

/// Routes an orchestrator lane's emissions: while ATTACHED they ride the turn's BrainEvent continuation (badges in the live turn)
final class LaneEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation?
    private var proactive: ProactiveMulticast?
    /// Set at detach: every proactive-side emission carries the id of the user turn that spawned the routine
    private var originUserTurnID: UUID?
    /// Has this lane asked for ANYTHING yet?
    /// PIN: KEPT, AND DELIBERATELY NOT USED TO SKIP THE JOIN GRACE
    private var skillInvocationSeen = false

    var sawSkillInvocation: Bool {
        lock.lock(); defer { lock.unlock() }
        return skillInvocationSeen
    }

    init(continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func emitSkillInvocation(
        reference: AbilitySkillReference, argumentsJSON: String, runID: String
    ) {
        lock.lock(); skillInvocationSeen = true; let turn = continuation; let channel = proactive; let origin = originUserTurnID; lock.unlock()
        if let turn {
            turn.yield(.skillInvocation(
                reference: reference, argumentsJSON: argumentsJSON, runID: runID))
        } else if let origin {
            channel?.yield(.skillInvocation(
                reference: reference,
                argumentsJSON: argumentsJSON,
                runID: runID,
                originUserTurnID: origin))
        }
    }

    /// ONE RECORD, TWO CHANNELS. The turn channel and the proactive channel carry the SAME value
    func emitSkillResult(_ record: BehavioralActionRecord) {
        lock.lock(); let turn = continuation; let channel = proactive; let origin = originUserTurnID; lock.unlock()
        if let turn {
            turn.yield(.skillResult(record: record))
        } else if let origin {
            channel?.yield(.skillResult(record: record, originUserTurnID: origin))
        }
    }

    func flipToDetached(_ multicast: ProactiveMulticast, originUserTurnID: UUID) {
        lock.lock()
        continuation = nil
        proactive = multicast
        self.originUserTurnID = originUserTurnID
        lock.unlock()
    }
}

final class TurnBox: @unchecked Sendable {
    private let lock = NSLock()
    private var epochValue: UInt64 = 0
    private var task: Task<Void, Never>?

    /// Claims the next epoch and cancels any installed in-flight turn task
    func reserve() -> UInt64 {
        lock.lock()
        epochValue += 1
        let fresh = epochValue
        let old = task
        task = nil
        lock.unlock()
        old?.cancel()
        return fresh
    }

    /// A turn retires its slot at every exit (defer in runTurn) so a later
    /// reserve() of a COMPLETED turn is a plain no-op cancel, never a
    /// takeover.
    func retire(_ epoch: UInt64) {
        lock.lock()
        if epoch == epochValue { task = nil }
        lock.unlock()
    }

    /// Installs the turn task for a reserved epoch. If something superseded
    /// between reserve and install, the newcomer is cancelled on arrival.
    func install(_ newTask: Task<Void, Never>, for epoch: UInt64) {
        lock.lock()
        let current = epoch == epochValue
        if current { task = newTask }
        lock.unlock()
        if !current { newTask.cancel() }
    }

    func cancelCurrent() {
        lock.lock()
        let old = task
        task = nil
        lock.unlock()
        old?.cancel()
    }

    func isCurrent(_ epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == epochValue
    }
}

/// A tiny async mutex. `acquire()` suspends until the gate is free and returns TRUE when the gate is actually held
final class LaneAttachment: @unchecked Sendable {
    private let lock = NSLock()
    private var attached = true

    var isAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return attached
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        attached = false
    }
}

final class AsyncGate: @unchecked Sendable {
    /// WHO IS WAITING ON THE OTHER SIDE OF THIS ROUND.
    enum Priority {
        /// A turn is still waiting on this round.
        case attached
        /// A detached routine — nobody is blocked on it.
        case detached
    }

    private let lock = NSLock()
    private var busy = false
    private var waiters: [
        (id: UUID, priority: Priority, continuation: CheckedContinuation<Bool, Never>)
    ] = []

    /// HOW MANY LANES ARE QUEUED BEHIND THE HOLDER, read for the lane log.
    var waiterCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    /// STARVATION IS BOUNDED BY THE WORLD, not by a fairness rule here.
    @discardableResult
    func acquire(priority: Priority = .detached) async -> Bool {
        let acquired: Bool = {
            lock.lock(); defer { lock.unlock() }
            if busy { return false }
            busy = true
            return true
        }()
        if acquired { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                if !busy {
                    busy = true
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                // Attached waiters go ahead of every detached one, and behind
                // every attached one already queued.
                switch priority {
                case .attached:
                    let insertion = waiters.lastIndex { $0.priority == .attached }
                        .map { waiters.index(after: $0) } ?? waiters.startIndex
                    waiters.insert((id, priority, continuation), at: insertion)
                case .detached:
                    waiters.append((id, priority, continuation))
                }
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                return
            }
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume(returning: false)
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume(returning: true)
        }
    }
}

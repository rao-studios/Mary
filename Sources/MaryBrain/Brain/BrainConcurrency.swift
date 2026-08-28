//
//  BrainConcurrency.swift
//  MaryBrain
//
//  The brain's lock-based concurrency primitives, moved whole from
//  MaryBrain.swift's preamble: `ProactiveMulticast`, `LaneEmitter`,
//  `TurnBox`, `AsyncGate`.
//
//  Everything moved verbatim; no behavior change. No access promotions were
//  needed — these were already internal top-level classes.
//

import MaryVoice
import Foundation

/// Synchronous, lock-guarded turn registration. Two jobs:
/// 1. `cancel()`/supersede always target the CORRECT turn (the old detached
///    `setCurrentTask` hop meant a cancel could race and hit the previous one).
/// 2. Every turn carries an epoch; history writes check it, so a stale turn —
///    e.g. one suspended in a subprocess when it was superseded — can never
///    append into the replacing turn's history.
/// Multicast for brain-initiated events outside any turn (routine progress,
/// spoken follow-ups). Lock-based so lane closures can yield synchronously.
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

/// Routes an orchestrator lane's emissions: while ATTACHED they ride the
/// turn's BrainEvent continuation (badges in the live turn); after DETACH
/// they flow to the proactive multicast so UI progress survives the turn's
/// completion.
final class LaneEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation?
    private var proactive: ProactiveMulticast?
    /// Set at detach: every proactive-side emission carries the id of the
    /// user turn that spawned the routine, so the transcript can anchor
    /// chips to the ORIGINATING bubble (turn-side events need no id — they
    /// ride the turn's own stream).
    private var originUserTurnID: UUID?
    /// Has this lane asked for ANYTHING yet?
    ///
    /// KEPT, AND DELIBERATELY NOT USED TO SKIP THE JOIN GRACE — that was
    /// tried and reverted, and the reason is worth leaving here so it is not
    /// tried again the same way.
    ///
    /// The 250 ms grace is dead time on a greeting: the executor is told to
    /// answer pure conversation with NOOP, so the turn buys a quarter second
    /// of silence waiting for nothing. The obvious fix is to skip the wait
    /// when no Skill has been called. It does not work, because the check
    /// happens IMMEDIATELY AFTER THE LANE SPAWNS — the lane has not run a
    /// single round yet, so this is false on essentially every turn, and
    /// skipping on it detaches lanes that were about to do real work.
    /// `TakeoverTests`, `PostActionEfficiencyTests` and the follow-up merge
    /// suites all fail, one with an index-out-of-range crash.
    ///
    /// A real fix has to distinguish "has not called a Skill YET" from "will
    /// not call one", which nothing at spawn time can. The honest lever is
    /// the grace constant itself, or a signal from the lane's first round.
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

    /// ONE RECORD, TWO CHANNELS. The turn channel and the proactive channel
    /// carry the SAME value; only the origin id differs, because a detached
    /// routine's records belong to the episode that started it rather than to
    /// whatever turn is open when they land.
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

    /// Claims the next epoch and cancels any installed in-flight turn task —
    /// the epoch advances BEFORE the cancel so the old turn's writes die
    /// immediately, even while it unwinds. Overlap and amend both come
    /// through here; whether the old EXCHANGE is removed is the actor's
    /// decision (openExchange), not this box's.
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

/// A tiny async mutex. `acquire()` suspends until the gate is free and
/// returns TRUE when the gate is actually held; the CALLER then runs its
/// critical section in its own task (so cancellation still propagates into
/// it) and `release()`s — only when it held. Cancellation-responsive: a
/// barged-in/superseded waiter is removed from the FIFO queue and resumed
/// with FALSE immediately, so dead lanes never hold a slot ahead of live
/// ones (they were part of the detach feedback loop).
/// WHETHER THE LANE'S TURN IS STILL WAITING ON IT.
///
/// A lane starts ATTACHED — the user is in front of the app, watching a reply
/// that has not arrived — and becomes DETACHED at the join grace, after which
/// nothing is blocked on its next round. The lane cannot work this out for
/// itself: the decision is made by `seerTurn` long after the lane started, and
/// the lane is by then an unstructured task with no view of its own turn.
///
/// Two readers. The lane log needs it to tell a slow round apart from a round
/// nobody is waiting on, and `AsyncGate` needs it to let a live turn past a
/// queue of background ones.
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
    ///
    /// Strict FIFO was wrong in one specific way, and it was the way that
    /// mattered: a turn the user is sitting in front of queued behind however
    /// many BACKGROUND rounds happened to be in line. With the local MLX
    /// engine every generation round in the process serializes here, so five
    /// detached routines are a queue up to fifty rounds deep — and the live
    /// turn behind them cannot make its 250 ms join grace no matter how small
    /// its own request is, so it detaches too, and now there are six. The
    /// `lanes` log has been recording that loop; this is the fix for it.
    ///
    /// Two tiers only, and FIFO inside each. A priority NUMBER would invite
    /// tuning, and there is exactly one distinction that is real here: is a
    /// person waiting, or is this work nobody is blocked on.
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
    ///
    /// The regression this measures is queueing, not work: with the local MLX
    /// engine every generation round in the process is serialized here, so a
    /// depth of four means the next turn cannot possibly make its 250 ms join
    /// grace no matter how fast its own round is. Without this number a slow
    /// turn and a queued turn are indistinguishable in the log.
    var waiterCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    /// STARVATION IS BOUNDED BY THE WORLD, not by a fairness rule here.
    ///
    /// A detached waiter can in principle be passed by attached ones forever.
    /// In practice attached rounds arrive only as fast as a person types or
    /// speaks, each one takes a bounded number of rounds, and a routine that
    /// waits too long is expired by its own watchdog and says so out loud —
    /// which is a better outcome than the status quo, where the LIVE turn was
    /// the one made to wait. An ageing rule would trade a loud, already-handled
    /// failure for a quiet return of the regression this exists to fix.
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

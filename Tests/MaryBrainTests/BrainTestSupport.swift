//
//  BrainTestSupport.swift
//  MaryBrainTests
//
//  WHAT: Shared arrival signal and quiescence helpers for turn-loop suites.
//  OUT:  ArrivalSignal
//  PIN:  A parked dispatcher test ends with awaitQuiescenceForTesting
//

import Foundation

/// Bounds-guarded index into a stub snapshot: nil instead of a trap when the
/// timing-determined array is short. Pair it with `try #require` (the house
/// form) so a missing element is a recorded miss, never a signal-5 that
/// takes the whole test process down.
extension Array {
    subscript(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A counted arrival signal — the replacement for `try await Task.sleep(…)`
/// as a way of saying "the other turn has got there by now".
///
/// THE FAILURE THIS PREVENTS (measured, not suspected): the overlap-during-grace
/// tests injected their second turn with a fixed 100 ms sleep against a REAL
/// 250 ms wall-clock join grace. Under full-suite contention the sleep overshot,
/// the overlap landed after turn 1 had already retired, and the assertion failed
/// because THE SCENARIO NEVER HAPPENED — the events of one such failure were a
/// plain `turnBegan → token → completed` with no supersede in them at all. A
/// timer cannot express "turn 1 is inside its join grace"; an arrival can.
///
/// Waiters are resumed OUTSIDE the lock, and a waiter whose target has already
/// been reached returns without suspending — so `advance()` may run before or
/// after `wait(until:)` with the same result.
///
/// CANCELLATION resumes the waiter early (Subprocess's single-resolve funnel:
/// one `resolved` flag per waiter, resume outside the lock). A lane parked in
/// `wait(until:)` must not ignore cancellation forever — it is what lets
/// `cancelRoutinesForTesting()` terminate. A cancelled wait returns without
/// its target having been reached; callers being torn down must not read that
/// return as the arrival.
final class ArrivalSignal: @unchecked Sendable {
    /// One waiter, resolvable exactly once — by its arrival or by
    /// cancellation, whichever lands first.
    private final class Waiter {
        let target: Int
        var resolved = false
        var continuation: CheckedContinuation<Void, Never>?
        init(target: Int) { self.target = target }
    }

    private let lock = NSLock()
    private var arrivals = 0
    private var waiters: [Waiter] = []

    /// One arrival. Safe to call from any thread, including inside a fake's
    /// synchronous body.
    func advance() {
        lock.lock()
        arrivals += 1
        let reached = arrivals
        var ready: [CheckedContinuation<Void, Never>] = []
        for waiter in waiters where waiter.target <= reached && !waiter.resolved {
            waiter.resolved = true
            if let continuation = waiter.continuation {
                waiter.continuation = nil
                ready.append(continuation)
            }
        }
        waiters.removeAll { $0.resolved }
        lock.unlock()
        for continuation in ready { continuation.resume() }
    }

    /// Suspends until the `target`-th arrival has happened — or until the
    /// surrounding task is cancelled, whichever comes first.
    func wait(until target: Int) async {
        let waiter = Waiter(target: target)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if waiter.resolved {
                    // Cancelled before the wait was even installed.
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if arrivals >= target {
                    waiter.resolved = true
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiter.continuation = continuation
                waiters.append(waiter)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiter.continuation
            waiter.continuation = nil
            let alreadyResolved = waiter.resolved
            waiter.resolved = true
            waiters.removeAll { $0 === waiter }
            lock.unlock()
            if !alreadyResolved, let continuation { continuation.resume() }
        }
    }
}

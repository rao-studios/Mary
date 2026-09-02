//
//  BrainTestSupport.swift
//  MaryBrainTests
//
//  WHAT: Shared arrival signal and quiescence helpers for turn-loop suites.
//  OUT:  ArrivalSignal
//  PIN:  A parked dispatcher test ends with awaitQuiescenceForTesting
//

import Foundation
@testable import MaryAmbient
@testable import MaryFoundation

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

/// A capability graph that answers only the question `AmbientPlace.focus`
/// asks: WHICH ABILITIES ARE DISCIPLINES.
///
/// The discipline axis is open now — it is whatever installed packages declare
/// `paradigm: .discipline` — so a place cannot tell a craft from an expertise
/// without a graph in view. Tests that assert on a place's discipline must
/// therefore state which crafts exist, the same way they already state which
/// applications are registered.
struct DisciplineGraph: AbilityCapabilityIndex {
    var disciplineIDs: [AbilityID]

    init(_ disciplineIDs: [AbilityID]) { self.disciplineIDs = disciplineIDs }

    /// Derived from real packages, so the fixture tracks what actually ships
    /// rather than a remembered copy of it.
    init(declaredBy packages: [MaryAbilityPackage]) {
        disciplineIDs = packages
            .filter { $0.paradigm == .discipline }
            .map(\.ability.id)
            .sorted { $0.rawValue < $1.rawValue }
    }

    let revision = UUID()
    func requestedAbilities(in _: String) -> Set<AbilityID> { [] }
    var disciplines: [AbilityID] { disciplineIDs }
}

/// SCOPE A WHOLE WORLD: the applications that are registered AND the graph
/// that says which of their Abilities are crafts.
///
/// These two always travel together now. A roster alone leaves every place
/// discipline-less, because `AmbientPlace.focus` can no longer read a craft
/// off a frozen enum — it asks the installed graph. Tests that state one
/// without the other pass or fail on whichever suite last installed a global
/// provider, which is exactly the flake this replaces.
func withScopedWorld<T>(
    roster: any AmbientApplicationIndex,
    disciplines: [AbilityID] = [.coding, .writing],
    _ body: () async throws -> T
) async rethrows -> T {
    try await AmbientCapabilityIndexProvider.$scoped.withValue(DisciplineGraph(disciplines)) {
        try await AmbientApplicationIndexProvider.$scoped.withValue(roster) {
            try await body()
        }
    }
}

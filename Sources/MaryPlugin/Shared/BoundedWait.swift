//
//  BoundedWait.swift
//  MaryBrain
//
//  ONE RULE, and it is the whole file: a hung dependency must degrade to an
//  honest failure, never to an unbounded wait.
//
//  THE FAILURE THIS PREVENTS (confirmed against a live user session): "what
//  are my calendar events tomorrow" spoke its acknowledgement, rendered its
//  chip, and then produced nothing for a minute or two. Three of the awaits
//  on that path had no deadline at all — an EventKit predicate query held
//  synchronously on an actor's thread, a `fetchReminders` continuation that
//  nothing could ever cancel, and a `.notDetermined` TCC request awaiting a
//  modal dialog that had landed on another Space. Every one of them is
//  bounded by this helper now.
//
//  WHY NOT `withTaskGroup`. A task group awaits every child before it
//  returns, so a child blocked inside a NON-CANCELLABLE dependency — a
//  wedged XPC round trip, a dialog nobody can see — hangs the group as well
//  and the timeout becomes decoration. `bounded` spawns the work
//  UNSTRUCTURED and resolves a one-shot continuation from whichever side
//  finishes first; the loser is cancelled and then abandoned. That is the
//  difference between a timeout that returns and one that only claims to.
//
//  The precedent in this package is `Subprocess.run`'s watchdog: attach the
//  canceller before starting, arm a deadline on a background queue, and
//  resolve the continuation EXACTLY ONCE through a lock-guarded box — a
//  double resume on a checked continuation traps the process.
//

import Foundation
import os

/// Lock-guarded, resume-exactly-once delivery of a raced result. Written for
/// the case where the value may arrive BEFORE the continuation is attached
/// (a `DispatchQueue` block can finish while the enclosing
/// `withCheckedContinuation` body is still running), which is why the result
/// is parked rather than dropped.
public final class RaceBox<T: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var parked: T??
    private var resolved = false

    /// Called from inside `withCheckedContinuation`, before any racer can win.
    public func attach(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        if let parked {
            resolved = true
            self.parked = nil
            lock.unlock()
            continuation.resume(returning: parked)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// The first caller wins; every later one is a no-op. `nil` is the
    /// deadline's own answer — "nobody came back in time".
    public func finish(_ value: T?) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        if let continuation {
            resolved = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            parked = .some(value)
            lock.unlock()
        }
    }
}

/// A one-way OFF switch for the side effects of work that lost a race.
///
/// WHY IT EXISTS. `bounded` releases the caller and then CANCELS the loser —
/// but cancellation is a request, and the loser may still be between two
/// awaits with a `continuation.yield` ahead of it. On the follow-up path that
/// yield is a `.followUpToken`: a token arriving after the fallback line has
/// already been spoken and `.followUpCompleted` sent re-opens the transcript's
/// per-origin accumulation, which then never completes — a dangling half
/// bubble, and exactly the late-append shape this whole round is closing.
/// Close the gate before speaking the fallback and a late token is a no-op.
public final class EmissionGate: @unchecked Sendable {
    public init() {}


    private let state = OSAllocatedUnfairLock<Bool>(initialState: true)

    /// May the producer still emit? Checked immediately before each yield.
    public var isOpen: Bool { state.withLock { $0 } }

    /// One-way and idempotent — nothing re-opens a gate.
    public func close() { state.withLock { $0 = false } }
}

/// Run `work`, or give up on it after `seconds`. `nil` means the deadline won.
///
/// The abandoned work is always a READ on the paths that use this — nothing
/// is left half-mutated by walking away from it.
public func bounded<T: Sendable>(
    _ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T
) async -> T? {
    let box = RaceBox<T>()
    let worker = Task { box.finish(await work()) }
    let deadline = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        box.finish(nil)
    }
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        box.attach(continuation)
    }
    // The loser is asked to stop. If it cannot — the whole reason this helper
    // exists — it dies on its own time with nobody waiting on it.
    worker.cancel()
    deadline.cancel()
    return result
}

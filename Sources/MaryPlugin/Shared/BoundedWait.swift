//
//  BoundedWait.swift
//  MaryBrain
//
//  WHAT: Poll until a predicate, then stop. Named bound, named miss.
//  OUT:  activation / write verify callers

import Foundation
import os

/// Lock-guarded, resume-exactly-once delivery of a raced result.
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
    /// PIN: `resolved` is set the moment a value is claimed, park included —
    ///      a value sitting unattached is still the FIRST answer, and a
    ///      second `finish` (the deadline arriving after a fast success, or
    ///      the reverse) must find the box already closed, not overwrite it.
    public func finish(_ value: T?) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        if let continuation {
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
public final class EmissionGate: @unchecked Sendable {
    public init() {}


    private let state = OSAllocatedUnfairLock<Bool>(initialState: true)

    /// May the producer still emit? Checked immediately before each yield.
    public var isOpen: Bool { state.withLock { $0 } }

    /// One-way and idempotent — nothing re-opens a gate.
    public func close() { state.withLock { $0 = false } }
}

/// Run `work`, or give up on it after `seconds`. `nil` means the deadline won.
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

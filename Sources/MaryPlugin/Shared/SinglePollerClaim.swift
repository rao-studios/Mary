//
//  SinglePollerClaim.swift
//  MaryBrain
//
//  A support plugin's `activate()`/`deactivate()` pair around one polling
//  Task, guarded so concurrent activates can't each store a poller. Four
//  watchers (Pages, Xcode, Applications, DocumentCorpus) hand-rolled this
//  identical create-then-claim-then-release dance around their own
//  `OSAllocatedUnfairLock<Task<Void, Never>?>`; this is that dance, named
//  once.
//

import os

public final class SinglePollerClaim: @unchecked Sendable {

    private let box = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    public init() {}

    public var isActive: Bool { box.withLock { $0 != nil } }

    /// Create-then-claim in one lock so concurrent activates can't each store
    /// a poller (the loser is cancelled; it exits on its first check).
    /// Returns `true` iff this call won the race and `loop` is now the
    /// registered poll loop.
    @discardableResult
    public func claim(_ loop: @escaping @Sendable () async -> Void) -> Bool {
        let task = Task { await loop() }
        let claimed = box.withLock { existing -> Bool in
            guard existing == nil else { return false }
            existing = task
            return true
        }
        if !claimed { task.cancel() }
        return claimed
    }

    /// Cancel and clear whichever task is registered, if any.
    public func release() {
        let task = box.withLock { existing -> Task<Void, Never>? in
            defer { existing = nil }
            return existing
        }
        task?.cancel()
    }
}

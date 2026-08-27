//
//  StageArbiter.swift
//  MaryBrain
//
//  THE STAGE = the frontmost app + synthetic input (keystrokes, menu
//  clicks). Only one action can hold it: a typed passage needs its target
//  frontmost between every chunk, and any binding that activates an app or
//  drives menus would yank that focus mid-word. Background actions (code
//  edits on disk, git, music playback) claim nothing and run freely in
//  parallel.
//
//  Policy (user decision): the NEWEST request wins. A stage-claiming binding
//  preempts the current holder before running — the holder's onPreempt
//  pauses it RESUMABLY (the typer saves its remainder), never a silent kill.
//

import Foundation

public final class StageArbiter: @unchecked Sendable {

    public static let shared = StageArbiter()

    private let lock = NSLock()
    private var holder: (id: UUID, owner: String, onPreempt: @Sendable () -> Void)?

    public init() {}

    /// Take the stage. `onPreempt` must make the holder step aside promptly
    /// and resumably (set a pause flag its loop checks). Release when done —
    /// defer-guarded, so an early exit can't leak the stage.
    public func claim(owner: String, onPreempt: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        holder = (id, owner, onPreempt)
        lock.unlock()
        return id
    }

    /// Atomically preempt and acquire the stage. Unlike the legacy two-call
    /// `preemptForNewClaim`/`claim` sequence, this never overwrites a holder
    /// that failed to release: the caller either owns the returned lease or
    /// receives nil without driving focus or synthetic input.
    public func acquire(
        owner: String,
        timeout: TimeInterval = 2,
        onPreempt: @escaping @Sendable () -> Void
    ) async -> UUID? {
        let id = UUID()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while !Task.isCancelled {
            let attempt = tryInstall(
                id: id,
                owner: owner,
                onPreempt: onPreempt)
            if attempt.acquired { return id }
            attempt.currentPreempt?()
            guard Date() < deadline else { return nil }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func tryInstall(
        id: UUID,
        owner: String,
        onPreempt: @escaping @Sendable () -> Void
    ) -> (acquired: Bool, currentPreempt: (@Sendable () -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        guard let current = holder else {
            holder = (id, owner, onPreempt)
            return (true, nil)
        }
        return (false, current.onPreempt)
    }

    public func release(_ id: UUID) {
        lock.lock()
        if holder?.id == id { holder = nil }
        lock.unlock()
    }

    /// Who holds the stage right now (spoken-name), nil when free.
    public func currentOwner() -> String? {
        lock.lock(); defer { lock.unlock() }
        return holder?.owner
    }

    private func currentHolder() -> (id: UUID, owner: String, onPreempt: @Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return holder
    }

    private func isHeld(by id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return holder?.id == id
    }

    /// A new stage action is about to run: ask the current holder to step
    /// aside and wait (≤2s) until it actually releases, so the newcomer
    /// never fights a live typing loop for focus. No holder → immediate.
    public func preemptForNewClaim() async {
        guard let current = currentHolder() else { return }
        current.onPreempt()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !isHeld(by: current.id) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

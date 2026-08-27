//
//  PausedTypingSession.swift
//
//  ONE VERB THE REASONING CORE NEEDS OVER A PAUSED WRITE: forget it.
//
//  When a turn supersedes an interrupted typing passage, the brain has to
//  say so — but the passage itself, its target, and its surface are the
//  typer's own business, and dragging them into the contract would drag the
//  whole adapter with them.
//
//  So the kit declares the verb and the typer installs the answer. Before
//  installation `clear()` is a no-op, which is correct: a process with no
//  typer has no paused write to forget.
//

import Foundation

public enum PausedTypingSession {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clearHandler: (@Sendable () -> Void)?

    /// Installed by the typing adapter. Idempotent; the last caller wins.
    public static func installClear(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        clearHandler = handler
    }

    /// Forgets any paused passage. A no-op when no typer is installed.
    public static func clear() {
        lock.lock()
        let handler = clearHandler
        lock.unlock()
        handler?()
    }
}

//
//  PausedTypingSession.swift
//  MaryPlugin
//
//  WHAT: Forget a paused write — the one verb the reasoning core needs.
//  IN:   brain (superseding turn)
//  OUT:  TyperPlugin.installClear
//  PIN:  Kit declares; typer installs. clear() is a no-op until then.
//

import Foundation

public enum PausedTypingSession {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clearHandler: (@Sendable () -> Void)?

    /// Installed by TyperPlugin. Idempotent; last caller wins.
    public static func installClear(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        clearHandler = handler
    }

    /// Forget any paused passage. No-op when no typer is installed.
    public static func clear() {
        lock.lock()
        let handler = clearHandler
        lock.unlock()
        handler?()
    }
}

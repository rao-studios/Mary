//
//  ApplicationHabitMemory.swift
//  MaryBrain
//
//  WHAT: Where "which app you reach for" lives — personal memory, not a file.
//  IN:   a granted successful dispatch that landed in a known application
//  OUT:  the ranked expertise for a discipline, restored at launch
//  PIN:  INVERSION, NOT A DIRECT CALL — the same seam shape, and the same
//        layering reason, as `RoutingHabitMemory`: MaryBrain does not
//        depend on MaryTotem, so the runtime installs a backend that does.
//
import Foundation
import MaryFoundation

/// Which application this person reaches for, per discipline.
///
/// A HABIT IS PERSONAL MEMORY. Whether you play music in Apple Music or in
/// Spotify belongs to the person, should follow them to another machine, and
/// should be forgettable in one gesture — the totem paradigm, not a defaults
/// key. It is deliberately NOT retrieved by resemblance: a tally is asked for
/// by discipline and read whole, so the backend stores one ledger per
/// discipline rather than one row per act.
public protocol ApplicationHabitMemory: Sendable {

    /// Persist this discipline's whole ledger, replacing what was there.
    /// Fire-and-forget: a turn must never wait to be taught.
    func remember(_ habits: [ApplicationHabit], discipline: AbilityID) async

    /// Everything remembered for one discipline. Empty is the honest answer
    /// for a fresh install and for an unreachable backend alike.
    func recall(discipline: AbilityID) async -> [ApplicationHabit]
}

/// The answer before anything is installed, and whenever the backend is
/// unreachable: nothing remembered, nothing recalled. Deliberately not an
/// error — a routing turn with no habits falls back to static preference,
/// which is exactly how a fresh install behaves.
public struct EmptyApplicationHabitMemory: ApplicationHabitMemory {
    public init() {}
    public func remember(_: [ApplicationHabit], discipline _: AbilityID) async {}
    public func recall(discipline _: AbilityID) async -> [ApplicationHabit] { [] }
}

public enum ApplicationHabitMemoryProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (@Sendable () -> any ApplicationHabitMemory)?

    /// Task-tree backend; `current` prefers it over the process-wide install.
    @TaskLocal public static var scoped: (any ApplicationHabitMemory)?

    public static func install(_ resolve: @escaping @Sendable () -> any ApplicationHabitMemory) {
        lock.lock()
        defer { lock.unlock() }
        provider = resolve
    }

    /// Whether anything is installed at all, so a launch with no backend does
    /// not pay a scheduling hop to be told there is nothing to restore.
    public static var isInstalled: Bool {
        if scoped != nil { return true }
        lock.lock()
        defer { lock.unlock() }
        return provider != nil
    }

    public static var current: any ApplicationHabitMemory {
        if let scoped { return scoped }
        lock.lock()
        let resolved = provider
        lock.unlock()
        return resolved?() ?? EmptyApplicationHabitMemory()
    }
}

//
//  RoutingExemplarMemory.swift
//  MaryBrain
//
//  WHAT: Where settled routing lessons live — personal memory, not a cache file.
//  IN:   a granted successful dispatch
//  OUT:  the nearest past queries to this turn's words
//  PIN:  INVERSION, NOT A DIRECT CALL. MaryBrain does not depend on MaryTotem;
//        the runtime installs a backend that does. Same shape as
//        `AmbientCapabilityIndexProvider`, for the same layering reason.
//
import Foundation

/// How this user has asked for things before.
///
/// A ROUTING EXEMPLAR IS PERSONAL MEMORY, which is why this is a memory seam
/// and not a store: the lesson "when I say *the usual mix*, I mean that
/// playlist" belongs to the person, should follow them to another machine, and
/// is retrieved by resemblance — all three of which are the totem paradigm and
/// none of which a JSON file in Application Support can do.
public protocol RoutingExemplarMemory: Sendable {

    /// Remember that these words settled on this Skill under this intent.
    /// Fire-and-forget: a turn must never wait to be taught.
    func remember(_ exemplar: RoutingExemplar) async

    /// The nearest settled queries to `utterance`.
    ///
    /// A CANDIDATE RETRIEVER, NOT A SCORER. Whatever similarity the backend
    /// used to find these is in ITS embedding space; the caller re-scores the
    /// returned text in the space its authored corpus lives in. Mixing the two
    /// against one floor would be quietly, unfixably wrong.
    func recall(near utterance: String, limit: Int) async -> [RoutingExemplar]
}

/// The answer before anything is installed, and whenever the backend is
/// unreachable: nothing remembered, nothing recalled. Deliberately not an
/// error — routing without exemplars is the authored corpus alone, which is
/// exactly how a fresh install behaves.
public struct EmptyRoutingExemplarMemory: RoutingExemplarMemory {
    public init() {}
    public func remember(_: RoutingExemplar) async {}
    public func recall(near _: String, limit _: Int) async -> [RoutingExemplar] { [] }
}

public enum RoutingExemplarMemoryProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (@Sendable () -> any RoutingExemplarMemory)?

    /// Task-tree backend; `current` prefers it over the process-wide install.
    @TaskLocal public static var scoped: (any RoutingExemplarMemory)?

    public static func install(_ resolve: @escaping @Sendable () -> any RoutingExemplarMemory) {
        lock.lock()
        defer { lock.unlock() }
        provider = resolve
    }

    /// Whether anything is installed at all. A turn with no backend must not
    /// pay a scheduling hop to be told there is nothing to recall.
    public static var isInstalled: Bool {
        if scoped != nil { return true }
        lock.lock()
        defer { lock.unlock() }
        return provider != nil
    }

    public static var current: any RoutingExemplarMemory {
        if let scoped { return scoped }
        lock.lock()
        let resolved = provider
        lock.unlock()
        return resolved?() ?? EmptyRoutingExemplarMemory()
    }
}

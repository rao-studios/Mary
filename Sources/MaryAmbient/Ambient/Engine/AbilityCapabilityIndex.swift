//
//  AbilityCapabilityIndex.swift
//
//  WHAT THE AMBIENT LAYER NEEDS TO KNOW ABOUT WHAT THIS MACHINE CAN DO — and
//  nothing more than that.
//
//  Routing an utterance needs one fact from the capability graph: which
//  Abilities the words are asking for. It does not need the frozen registry,
//  the adapter join, the availability lattice, or any of the machinery that
//  produces that answer. So this is the whole seam — one method and a revision
//  to stamp a trace with.
//
//  Keeping it this narrow is the point. It is what lets this package build
//  against MaryFoundation alone, and it is what makes the layer portable: a host
//  with an entirely different notion of "capability" satisfies two members and
//  the attention model works unchanged.
//

import Foundation

/// The capability graph, as the ambient layer sees it.
public protocol AbilityCapabilityIndex: Sendable {
    /// Identity of the frozen revision this index describes, stamped into traces
    /// so a recorded turn can be tied back to the registry that ran it.
    var revision: UUID { get }

    /// The Abilities this utterance is asking for.
    func requestedAbilities(in utterance: String) -> Set<AbilityID>

    /// The role an Ability plays in the installed graph. Nil when this index
    /// does not know the Ability — the caller then falls back to structure.
    func paradigm(of abilityID: AbilityID) -> AbilityParadigm?
}

public extension AbilityCapabilityIndex {
    func paradigm(of abilityID: AbilityID) -> AbilityParadigm? { nil }
}

/// The answer when nothing has been installed: no Abilities requested.
///
/// Deliberately not an error. A turn can run before the registry has loaded,
/// and "I know of no capabilities" is the honest reading of that state.
public struct EmptyAbilityCapabilityIndex: AbilityCapabilityIndex {
    public static let revisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public init() {}
    public var revision: UUID { Self.revisionID }
    public func requestedAbilities(in _: String) -> Set<AbilityID> { [] }
    public func paradigm(of _: AbilityID) -> AbilityParadigm? { nil }
}

/// Where the ambient layer looks when a caller did not hand it an index.
///
/// The owner of the real capability graph installs a provider once at
/// configuration; everything below reads through this. An inversion rather
/// than a direct call, because the graph lives a layer above and this package
/// must not name it.
public enum AmbientCapabilityIndexProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (@Sendable () -> any AbilityCapabilityIndex)?

    /// Installs the live index. Idempotent; the last caller wins.
    public static func install(_ provider: @escaping @Sendable () -> any AbilityCapabilityIndex) {
        lock.lock()
        defer { lock.unlock() }
        Self.provider = provider
    }

    /// The installed index, or an empty one when nothing has been installed.
    public static var current: any AbilityCapabilityIndex {
        lock.lock()
        let resolved = provider
        lock.unlock()
        return resolved?() ?? EmptyAbilityCapabilityIndex()
    }
}

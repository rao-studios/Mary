//
//  AbilityCapabilityIndex.swift
//  MaryAmbient
//
//  WHAT: What the ambient layer needs to know about what this machine can do.
//  OUT:  requestedAbilities / paradigm. Host installs via AmbientCapabilityIndexProvider.
//  PIN:  This package must not name the capability graph; inversion, not a direct call.
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

/// The answer when nothing has been installed: no Abilities requested. Deliberately not an
/// error. A turn can run before the registry has loaded, and "I know of no capabilities" is
/// the honest reading of that state.
public struct EmptyAbilityCapabilityIndex: AbilityCapabilityIndex {
    public static let revisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public init() {}
    public var revision: UUID { Self.revisionID }
    public func requestedAbilities(in _: String) -> Set<AbilityID> { [] }
    public func paradigm(of _: AbilityID) -> AbilityParadigm? { nil }
}

/// Where the ambient layer looks when a caller did not hand it an index. The owner of the
/// real capability graph installs a provider once at configuration.
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

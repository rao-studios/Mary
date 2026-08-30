//
//  PassageRecipes.swift
//  MaryBrain
//
//  WHAT: Passage skill surface — which world, which backing.
//  OUT:  PassageRecipes+Skills / +WhichPlace / +MintingHandle

import AppKit
import Foundation

public enum PassageRecipes {

    /// WHICH BACKING ANSWERS FOR WHICH WORLD — asked here, answered above. Nil before
    /// installation is the honest state, not a bug: a process with no plugins registered
    /// has no editable worlds, and the caller already has a sentence for that.
    private static let resolverLock = NSLock()
    nonisolated(unsafe) private static var backingResolver:
        (@Sendable (AmbientPlace) -> PassageBacking?)?

    /// Installed once by the adapter layer. Idempotent; the last caller wins.
    public static func installBackingResolver(
        _ resolve: @escaping @Sendable (AmbientPlace) -> PassageBacking?
    ) {
        resolverLock.lock()
        defer { resolverLock.unlock() }
        backingResolver = resolve
    }

    public static func backing(for place: AmbientPlace) -> PassageBacking? {
        resolverLock.lock()
        let resolve = backingResolver
        resolverLock.unlock()
        return resolve?(place)
    }

    /// The built-in spelling.
    public static func backing(for world: AmbientWorld) -> PassageBacking? {
        backing(for: AmbientPlace.lane(world))
    }

    /// Whether ANYONE has installed the resolver — the wiring fact `route`'s
    /// debug assertion distinguishes from an honestly backing-less world.
    public static var hasBackingResolver: Bool {
        resolverLock.lock()
        defer { resolverLock.unlock() }
        return backingResolver != nil
    }


}

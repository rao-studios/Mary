//
//  PassageRecipes.swift
//  MaryBrain
//
//  THE FIVE VERBS, REGISTERED ONCE, FOR EVERY WORLD — and the router that
//  decides which world a call is about.
//
//  "This implementation should not be pages specific. This paradigm should
//  apply to all applications in the workspace world, XCode, Scrivener etc. …
//  so we start treating ambient contexts as a holistic world problem than a
//  app-scope app-specific issue." That is the user's own framing of the scope,
//  and it is why these are five Skills rather than fifteen: one set of names
//  the model learns once, whose document's world rides on the HANDLE rather
//  than on which Skill was invoked.
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHY `typer` OWNS THEM, AND NOT A NEW PLUGIN
//  ─────────────────────────────────────────────────────────────────────────
//
//  A new owner would break `AmbientContextStoreTests.everyPluginOwnerIsAWorld`,
//  which asserts plugin owners and `AmbientWorld` cases are in bijection — and
//  the repair for that would be a new world with no honest `worldClass`, since
//  a revision is not a PLACE. `typer` is right on the merits, not merely
//  available:
//
//    - its `worldClass` is `.service`, the class whose own doc comment reads
//      "hands and services rather than a place with contents";
//    - it already owns the only write verb in the tree, and this is the other
//      half of that same act — `type_at_cursor` is COMPOSITION, these are
//      REVISION, and the two belong beside each other where the model reads
//      them together;
//    - it already resolves a TARGET APP per call rather than being bound to
//      one, which is exactly the shape a cross-world verb needs.
//
//  ─────────────────────────────────────────────────────────────────────────
//  WHY THE FOUR EDIT VERBS CLAIM THE STAGE
//  ─────────────────────────────────────────────────────────────────────────
//
//  `SkillBinding.stage` is declared STATICALLY, per binding, and the Pages
//  backing MAY type: `PagesPassageWriter` falls back to keystrokes when
//  Accessibility refuses the setter. A binding that may type and does not claim
//  the stage never runs `StageArbiter.preemptForNewClaim()`, so a passage the
//  typer is putting on the page right now dies mid-word to the focus steal
//  instead of pausing resumably. Overstating it on a disk-only Xcode edit costs
//  one no-op call; understating it on the one path that types costs the user
//  their sentence.
//
//  `find_passage` is a read and claims nothing — it never brings a window
//  forward and never posts a key.
//

import AppKit
import Foundation

public enum PassageRecipes {

    /// WHICH BACKING ANSWERS FOR WHICH WORLD — asked here, answered above.
    ///
    /// The kit describes what a `PassageBacking` IS; only the adapter layer can
    /// say who has one, because saying so means naming four concrete plugins.
    /// So the answer is installed rather than switched on, and this file stays
    /// free of every adapter it serves.
    ///
    /// Nil before installation is the honest state, not a bug: a process with no
    /// plugins registered has no editable worlds, and the caller already has a
    /// sentence for that.
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

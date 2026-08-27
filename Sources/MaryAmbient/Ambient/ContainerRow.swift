//
//  ContainerRow.swift
//  MaryBrain
//
//  A CONTAINER: something the user can point at that HOLDS content — a
//  TextEdit window, a Pages document, a Scrivener binder item, a note, an
//  email.
//
//  ═══════════════════════════════════════════════════════════════════════
//  A CONTAINER IS NOT A PASSAGE, and the two must not share a ledger.
//
//                    span (`Passage`)              container
//    born of         Mary's own read             it was already there
//    identity        world|documentKey|hash(text)  the world's own documentKey
//    dies by         SUPERSESSION — an 8-hop       CLOSURE — "that note isn't
//                    forwarding chain, because     open any more". A forwarding
//                    edited words have a           address for a closed window
//                    successor                     means nothing
//    retention       1200 s, DERIVED from          none — liveness is "is it
//                    `AmbientFact.defaultRetention`  still open", re-read every
//                    because `[S#]` is rendered    turn from the live roster
//                    in the prompt beside a
//                    `namedRead` fact
//
//  That retention coupling is the decisive one. `PassageRegistry`'s window
//  equals the ambient store's SO THE PROMPT CAN NEVER SHOW A HANDLE THE
//  REGISTRY HAS DROPPED. Container handles never enter the prompt (they appear
//  only inside a roster Skill result), so that constraint does not apply — and
//  forcing it on them would expire `[W3]` twenty minutes into a session for a
//  note still sitting open on screen.
//  ═══════════════════════════════════════════════════════════════════════
//
//  PURE. A row is a value a world hands over; nothing here spawns anything.
//

import Foundation

/// ONE CONTAINER, as its world reports it.
public struct ContainerRow: Sendable, Equatable {

    /// The world's own `documentKey` — the SAME string its `PassageBacking`
    /// answers `bodyForDocument` for. Never a second spelling of "which
    /// document": that is how `document 1` and the front window came to
    /// disagree in Pages.
    public var key: String

    /// What the window or document calls itself.
    public var title: String

    /// WHAT THE USER ACTUALLY CALLS IT BY, when the title does not
    /// distinguish — a first line, a synopsis, a subject.
    ///
    /// Measured, and this is why the field exists: all eleven of this user's
    /// TextEdit notes are named `Untitled N`. A resolver with only titles to
    /// match on would abstain on every one of them. It is also the only rung
    /// available to a world that can enumerate its containers but not read
    /// them.
    public var subtitle: String?

    /// The container's text, when it is already in hand.
    ///
    /// NIL MEANS UNREAD, NEVER EMPTY. A container whose body has not been read
    /// is one the content rung must SKIP — treating absence of evidence as
    /// evidence of absence is how a resolver becomes confident and wrong.
    public var body: String?

    /// Where this row sat in its world's own enumeration — z-order for
    /// windows, binder order for a manuscript. What an ordinal counts.
    public var listIndex: Int

    /// Is this the one the user is looking at? Excluded from every anaphoric
    /// answer: "the other one" and "the last one" both explicitly mean NOT
    /// this.
    public var isFront: Bool

    public init(
        key: String,
        title: String,
        subtitle: String? = nil,
        body: String? = nil,
        listIndex: Int,
        isFront: Bool = false
    ) {
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.listIndex = listIndex
        self.isFront = isFront
    }
}

/// HOW A WORLD PUBLISHES ITS CONTAINERS. One optional member on
/// `MaryAdapter`, defaulting nil — the shape `targetedRead`, `targetedEdit`
/// and `passageBacking` already use, so a world that has exactly one document
/// says nothing and costs nothing.
public struct ContainerRoster: Sendable {

    /// WHERE THESE CONTAINERS LIVE.
    ///
    /// A place rather than a world, because a registered application supplies
    /// containers too and it need not BE one of the built-in worlds.
    /// `ContainerRegistry` has been place-keyed all along; this was the last
    /// place that narrowed it on the way in. Every built-in caller keeps its
    /// spelling through `init(world:…)` below, and `world` still answers for
    /// the native projection — so this widening changes no behaviour today and
    /// is what lets a second manuscript application enrol its own `[D#]`.
    public var place: AmbientPlace

    public var world: AmbientWorld { place.world }

    /// The `HandleMap` prefix this world's containers are addressed by —
    /// `W` for TextEdit windows, `D` for Scrivener binder items. Registered in
    /// the table at the top of `PassageRegistry`.
    public var handlePrefix: String

    /// WHATEVER IS ALREADY IN HAND. NO I/O, EVER.
    ///
    /// This is the whole cost story of fluid reference. The resolver runs
    /// pre-model on EVERY turn, so a `cached` that spawned an Apple Event per
    /// world per turn would be unshippable — and it would spawn them on the
    /// overwhelming majority of turns, which name no container at all. This
    /// reads a lock box the world's watcher already fills.
    public var cached: @Sendable () -> [ContainerRow]

    /// The expensive enumeration, run only when the MODEL asks — a listing
    /// binding like `textedit_windows` or `binder_outline`. May spawn.
    public var list: (@Sendable () async -> [ContainerRow])?

    public init(
        place: AmbientPlace,
        handlePrefix: String,
        cached: @escaping @Sendable () -> [ContainerRow],
        list: (@Sendable () async -> [ContainerRow])? = nil
    ) {
        self.place = place
        self.handlePrefix = handlePrefix
        self.cached = cached
        self.list = list
    }

    /// The native spelling, so every built-in world's construction is unedited.
    public init(
        world: AmbientWorld,
        handlePrefix: String,
        cached: @escaping @Sendable () -> [ContainerRow],
        list: (@Sendable () async -> [ContainerRow])? = nil
    ) {
        self.init(
            place: .lane(world),
            handlePrefix: handlePrefix,
            cached: cached,
            list: list)
    }
}

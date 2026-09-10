//
//  ContainerRow.swift
//  MaryBrain
//
//  WHAT: A container — something the user can point at that holds content.
//  OUT:  ContainerRegistry. Sibling: Passage (span, not container).
//  PIN:  Born of the world's own documentKey; dies by closure, not supersession.
//

import Foundation

/// ONE CONTAINER, as its world reports it.
public struct ContainerRow: Sendable, Equatable {

    /// The world's own `documentKey` — the SAME string its `PassageBacking` answers
    /// `bodyForDocument` for. Never a second spelling of "which document": that is how
    /// `document 1` and the front window came to disagree in Pages.
    public var key: String

    /// What the window or document calls itself.
    public var title: String

    /// WHAT THE USER ACTUALLY CALLS IT BY, when the title does not distinguish.
    public var subtitle: String?

    /// The container's text, when it is already in hand. NIL MEANS UNREAD, NEVER EMPTY. A
    /// container whose body has not been read is one the content rung must SKIP.
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

/// HOW A WORLD PUBLISHES ITS CONTAINERS. One optional member on `MaryAdapter`, defaulting
/// nil — the shape `targetedRead`, `targetedEdit` and `passageBacking` already use, so a
/// world that has exactly one document says nothing and costs nothing.
public struct ContainerRoster: Sendable {

    /// WHERE THESE CONTAINERS LIVE. A place rather than a world, because a registered
    /// application supplies containers too and it need not BE one of the built-in worlds.
    /// `ContainerRegistry` has been place-keyed all along.
    public var place: AmbientPlace

    public var attention: AmbientAttention { place.attention }

    /// The `HandleMap` prefix this world's containers are addressed by —
    /// `W` for TextEdit windows, `D` for Scrivener binder items. Registered in
    /// the table at the top of `PassageRegistry`.
    public var handlePrefix: String

    /// WHATEVER IS ALREADY IN HAND. NO I/O, EVER. This is the whole cost story of fluid
    /// reference.
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
        attention: AmbientAttention,
        handlePrefix: String,
        cached: @escaping @Sendable () -> [ContainerRow],
        list: (@Sendable () async -> [ContainerRow])? = nil
    ) {
        self.init(
            place: .lane(attention),
            handlePrefix: handlePrefix,
            cached: cached,
            list: list)
    }
}

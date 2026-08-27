//
//  AmbientCaptureBuilder.swift
//  MaryAmbient
//
//  WHAT THE MODEL WAS GIVEN, WRITTEN DOWN — the input half of one behavioural
//  episode.
//
//  A turn's context is assembled, rendered into a prompt, and then, in every
//  build before this one, thrown away. What survived was counts: how many
//  blocks, how many characters, which keys. That is enough to debug a prompt
//  and nowhere near enough to learn from one, because the interesting question
//  about a turn is not "how much context was there" but "given THAT screen,
//  what did she do".
//
//  This builder answers by projecting the same inputs the renderer just used
//  into `AmbientCapture`. It runs BESIDE the renderer, never inside it:
//  `AmbientRanker.render` is untouched, so the bytes that reach the prompt are
//  exactly what they were and the prompt goldens hold. The two are fed from
//  one call site with one set of inputs, which is what keeps them describing
//  the same turn.
//
//  WHAT WAS INJECTED, NOT WHAT WAS HELD — and the ranking decides which. The
//  store knows more than any turn uses; capturing all of it would teach a
//  future model to act on context the live one never received, and would
//  widen what lands on disk to documents the turn never touched. So the
//  rendering's own `keys` are the filter: a fact is captured if and only if it
//  was rendered, in the order it was rendered.
//
//  THIS FILE OWNS THE TOKEN SPELLINGS, and that is its second job. Realms,
//  slots and provenance cross into the dataset as `String`, because a written
//  episode is a historical record and must not change meaning when an enum
//  case is renamed. Every one of those spellings is produced here, once, and
//  pinned by test — so the mapping is a decision in one file rather than a
//  habit spread across many.
//

import Foundation
import MaryFoundation

public enum AmbientCaptureBuilder {

    /// How many elements of one surface reach the dataset.
    ///
    /// A cap rather than everything: a busy window walks to a few hundred
    /// elements, most of them chrome nobody will ever act on, and an episode
    /// is written on every turn. The surface's own publication order is
    /// reading order, so the cap keeps the top of the window — where the
    /// document and its controls are — and `truncated` says it happened.
    public static let elementCap = 60

    /// Projects one turn's assembled context into the form the dataset holds.
    ///
    /// - Parameters:
    ///   - facts: every fact the store offered this turn, pre-ranking.
    ///   - surfaces: the tier-0 surfaces the renderer was given.
    ///   - rendering: what the renderer actually produced — the filter for
    ///     which facts were injected, and the rendered lines themselves.
    ///   - selection: the live selection, when one was in play.
    ///   - lead: the realm leading the turn, when one was.
    ///   - now: the moment the turn asked, for fact ages.
    public static func capture(
        facts: [AmbientFact],
        surfaces: [AmbientSurface],
        rendering: AmbientRendering,
        selection: AmbientSelectionHandoff? = nil,
        lead: AmbientRealm? = nil,
        at now: Date = Date()
    ) -> AmbientCapture {
        AmbientCapture(
            mode: rendering.mode.rawValue,
            lead: lead.map(token(for:)),
            surfaces: surfaces.map { surfaceCapture($0) },
            facts: injectedFacts(facts, rendering: rendering, at: now),
            selection: selection.map(selectionCapture),
            renderedSurfaceLines: rendering.surfaceLines,
            renderedBlocks: rendering.blocks,
            renderedMentions: rendering.mentions)
    }

    // MARK: - Facts

    /// The facts the rendering admitted, in the order it admitted them.
    ///
    /// Keyed rather than filtered by identity because `AmbientRendering.keys`
    /// is contracted to describe blocks + mentions IN ORDER, and that order is
    /// the model's reading order — which is information about what mattered,
    /// not incidental.
    static func injectedFacts(
        _ facts: [AmbientFact],
        rendering: AmbientRendering,
        at now: Date
    ) -> [FactCapture] {
        let byKey = Dictionary(facts.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return rendering.keys.compactMap { key in
            byKey[key].map { factCapture($0, at: now) }
        }
    }

    static func factCapture(_ fact: AmbientFact, at now: Date) -> FactCapture {
        FactCapture(
            place: token(for: fact.place),
            slot: token(for: fact.slot),
            text: fact.content,
            ageSeconds: max(0, now.timeIntervalSince(fact.capturedAt)),
            provenance: fact.provenance.rawValue)
    }

    // MARK: - Surfaces

    static func surfaceCapture(_ surface: AmbientSurface) -> SurfaceCapture {
        var records: [AXElementRecord] = []
        var frameless = 0
        for element in surface.elements.prefix(elementCap) {
            // NO FABRICATED GEOMETRY. A record's frame is not optional, and
            // filling a missing one with a zero rect would put a lie in the
            // dataset shaped exactly like evidence. The element is dropped and
            // counted instead, which keeps "a walked element has a frame" an
            // observable invariant rather than an assumption.
            guard let frame = element.frame else {
                frameless += 1
                continue
            }
            records.append(
                AXElementRecord(
                    identity: element.identity,
                    ordinal: element.ordinal,
                    role: element.role,
                    label: element.label,
                    kind: element.kind,
                    containerTrail: element.containerTrail,
                    isEnabled: element.isEnabled,
                    isFocused: element.isFocused,
                    appName: surface.application.name,
                    pid: surface.application.pid,
                    windowTitle: surface.activeWindow?.title ?? "",
                    frame: frame))
        }
        return SurfaceCapture(
            place: token(for: surface.place),
            application: CapturedApplication(
                name: surface.application.name,
                bundleID: surface.application.bundleID,
                pid: surface.application.pid),
            windowTitle: surface.activeWindow?.title,
            windowFrame: surface.activeWindow?.frame,
            elements: records,
            framelessDropped: frameless,
            truncated: surface.elements.count > elementCap,
            capturedAt: surface.capturedAt)
    }

    // MARK: - Selection

    static func selectionCapture(_ handoff: AmbientSelectionHandoff) -> SelectionCapture {
        SelectionCapture(
            place: token(for: AmbientRealm(world: handoff.world, application: handoff.application)),
            application: CapturedApplication(
                name: handoff.applicationID, bundleID: handoff.applicationID),
            text: handoff.text,
            truncated: handoff.truncated,
            // WHICH CHANNEL PROVED IT. Not decoration: the evidence channel
            // is what decides whether a selection may authorize a mutation,
            // so a dataset row without it cannot explain why one selection
            // was acted on and another only noted.
            channel: handoff.sourceEvidence.rawValue,
            capturedAt: handoff.capturedAt)
    }

    // MARK: - Tokens

    /// A realm as a dataset token.
    ///
    /// `AmbientRealm.token` is already the collision-free spelling the pane
    /// and the report split on, and reusing it is the point: a capture and a
    /// trace naming the same place must say the same word, or joining them
    /// later is guesswork.
    public static func token(for realm: AmbientRealm) -> String { realm.token }

    /// A slot as a dataset token.
    ///
    /// `AmbientSlot.token` carries the parameterized `namedRead` shape as
    /// well, so a read of a particular phrase stays distinguishable from a
    /// read of another — which is exactly the distinction a future model
    /// needs to learn what a named read is for.
    public static func token(for slot: AmbientSlot) -> String { slot.token }
}

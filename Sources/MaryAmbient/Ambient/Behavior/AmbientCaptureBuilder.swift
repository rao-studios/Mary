//
//  AmbientCaptureBuilder.swift
//  MaryAmbient
//
//  WHAT: What the model was given, written down — input half of one behavioural episode.
//  IN:   same inputs the prompt renderer used
//  OUT:  AmbientCapture. Durable learning → Totem
//  PIN:  Runs beside AmbientRanker.render, never inside it — prompt goldens hold.
//

import Foundation
import MaryFoundation

public enum AmbientCaptureBuilder {

    /// How many elements of one surface reach the dataset. A cap rather than everything: a busy
    /// window walks to a few hundred elements, most of them chrome nobody will ever act on, and
    /// an episode is written on every turn.
    public static let elementCap = 60

    /// Projects one turn's assembled context into the form the dataset holds. - Parameters: -
    /// facts: every fact the store offered this turn, pre-ranking. - surfaces: the tier-0
    /// surfaces the renderer was given. - rendering: what the renderer actually produced.
    public static func capture(
        facts: [AmbientFact],
        surfaces: [AmbientSurface],
        rendering: AmbientRendering,
        selection: AmbientSelectionHandoff? = nil,
        lead: AmbientPlace? = nil,
        realm: AmbientRealm? = nil,
        at now: Date = Date()
    ) -> AmbientCapture {
        // BOTH HALVES ARE RECORDED AS THEY ARRIVED, and this builder does not reconcile them.
        // `lead` is what the prompt actually used; `realm.place` is what the resolver recorded as
        // the where.
        return AmbientCapture(
            mode: rendering.mode.rawValue,
            lead: lead.map(token(for:)),
            surfaces: surfaces.map { surfaceCapture($0) },
            facts: injectedFacts(facts, rendering: rendering, at: now),
            selection: selection.map(selectionCapture),
            realm: realm.map(realmCapture),
            renderedSurfaceLines: rendering.surfaceLines,
            renderedBlocks: rendering.blocks,
            renderedMentions: rendering.mentions)
    }

    // MARK: - Facts

    /// The facts the rendering admitted, in the order it admitted them. Keyed rather than
    /// filtered by identity because `AmbientRendering.keys` is contracted to describe blocks +
    /// mentions IN ORDER, and that order is the model's reading order.
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
            // NO FABRICATED GEOMETRY. A record's frame is not optional, and filling a missing one with
            // a zero rect would put a lie in the dataset shaped exactly like evidence.
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
            place: token(for: AmbientPlace(attention: handoff.attention, application: handoff.application)),
            application: CapturedApplication(
                name: handoff.applicationID, bundleID: handoff.applicationID),
            text: handoff.text,
            truncated: handoff.truncated,
            // WHICH CHANNEL PROVED IT. Not decoration: the evidence channel is what decides whether a
            // selection may authorize a mutation, so a dataset row without it cannot explain why one
            // selection was acted on and another only noted.
            channel: handoff.sourceEvidence.rawValue,
            capturedAt: handoff.capturedAt)
    }

    // MARK: - Realm

    static func realmCapture(_ realm: AmbientRealm) -> RealmCapture {
        RealmCapture(
            need: NeedCapture(
                // SORTED, because a Set has no order and an unordered field
                // would make two identical turns produce two different rows —
                // undiffable, undeduplicatable, and impossible to compare.
                abilities: realm.need.abilities.map(\.rawValue).sorted(),
                discipline: realm.need.discipline.map(token(for:))),
            candidates: realm.candidates.map(candidateCapture),
            place: realm.place.map(token(for:)),
            decidedBy: realm.decidedBy?.rawValue)
    }

    static func candidateCapture(_ candidate: AmbientCandidate) -> CandidateCapture {
        CandidateCapture(
            place: token(for: candidate.place),
            conformsByAbilities: candidate.conformsByAbilities.map(\.rawValue).sorted(),
            conformsByDiscipline: candidate.conformsByDiscipline,
            targetClasses: candidate.targetClasses.sorted(),
            hasEyes: candidate.hasEyes,
            evidence: candidate.evidence.map(token(for:)),
            evidenceAgeSeconds: candidate.evidenceAgeSeconds)
    }

    // MARK: - Tokens

    /// A place as a dataset token. `AmbientPlace.token` is already the collision-free spelling
    /// the pane and the report split on, and reusing it is the point: a capture and a trace
    /// naming the same place must say the same word, or joining them later is guesswork.
    public static func token(for place: AmbientPlace) -> String { place.token }

    /// A discipline as a dataset token.
    public static func token(for focus: WorkspaceFocus) -> String {
        focus.rawValue
    }

    /// An evidence kind as a dataset token. Spelled here rather than read off the enum because
    /// its raw value is an Int — a ranking, not a name — and writing `2` into the dataset would
    /// record a comparison instead of a fact.
    public static func token(for evidence: FocusEvidenceKind) -> String {
        switch evidence {
        case .activity: return "activity"
        case .activation: return "activation"
        case .glance: return "glance"
        }
    }

    /// A slot as a dataset token. `AmbientSlot.token` carries the parameterized `namedRead`
    /// shape as well, so a read of a particular phrase stays distinguishable from a read of
    /// another.
    public static func token(for slot: AmbientSlot) -> String { slot.token }
}

//
//  WorkspaceFocusArbiter.swift
//  MaryBrain
//
//  WHAT: Which live place gets the full prompt section; others get one routing line.
//  IN:   live places + user intention signals
//  OUT:  lead / collapsed / unled
//  PIN:  Two full sections never coexist. Live is never silenced entirely. No signal → unled.
//
import Foundation
import MaryAmbient

public enum WorkspaceFocusArbiter {

    /// What the prompt renders, decided here rather than re-derived by
    /// whoever renders it.
    public struct PromptSections: Sendable, Equatable {
        /// The lead place's own lines, in full.
        public var leadContext: [String]
        /// One routing line per live place that did not lead. Never empty when
        /// a second place was live — see invariant 2.
        public var ambientNotes: [String]
        /// WHO OWNS `leadContext`. Nil exactly when `leadContext` is empty.
        public var leadPlace: AmbientPlace?
        /// WHERE THE LIVE WORK CAME FROM — stated by the branch that decided it.
        /// PIN: DELIBERATELY NOT DEFAULTED, and that is the point of the type.
        public var liveWorld: LiveWorkWorld

        public init(
            leadContext: [String] = [],
            ambientNotes: [String] = [],
            leadPlace: AmbientPlace? = nil,
            liveWorld: LiveWorkWorld
        ) {
            self.leadContext = leadContext
            self.ambientNotes = ambientNotes
            self.leadPlace = leadPlace
            self.liveWorld = liveWorld
        }
    }

    /// One live place's contribution, as its own watcher rendered it.
    /// PIN: THE LINES ARRIVE ALREADY RENDERED, because turning a live document into a sentence needs to know what that document…
    public struct Contribution: Sendable, Equatable {
        public var place: AmbientPlace
        /// The discipline this place registers for. Nil when the roster does not know
        public var discipline: WorkspaceFocus?
        /// The full section, if this place leads.
        public var full: [String]
        /// The one-line version, if it does not. Nil collapses to silence,
        /// which invariant 2 forbids for a live place — so a watcher that can
        /// contribute a full section must be able to contribute a line.
        public var ambient: String?
        /// This place has a LIVE DOCUMENT open, rather than a pile of
        /// deposits — and whether Mary holds the whole of it or a window onto
        /// part of it. Nil means deposits. See `LiveWorkWorld.document`.
        public var liveDocumentIsWhole: Bool?
        /// The user NAMED this place this turn (a literal name, or a routed
        /// selection that settled it).
        public var wasNamed: Bool

        public init(
            place: AmbientPlace,
            discipline: WorkspaceFocus? = nil,
            full: [String] = [],
            ambient: String? = nil,
            liveDocumentIsWhole: Bool? = nil,
            wasNamed: Bool = false
        ) {
            self.place = place
            self.discipline = discipline
            self.full = full
            self.ambient = ambient
            self.liveDocumentIsWhole = liveDocumentIsWhole
            self.wasNamed = wasNamed
        }

        /// A place with nothing to say is not live. Merely being OPEN is not a
        /// contribution — see `writingInPlay`.
        public var isLive: Bool { !full.isEmpty || ambient != nil }
    }

    // MARK: - Which discipline leads

    /// WHICH DISCIPLINE LEADS. Open over however many are installed: the
    /// asked-for one when it is actually live, else the first live discipline
    /// still in play.
    ///
    /// - Parameters:
    ///   - focus: the discipline the turn asked for, if any.
    ///   - live: the disciplines with a live contribution, IN REGISTRY
    ///     PRECEDENCE ORDER — the caller owns that order because only it can
    ///     ask the registry.
    ///   - inPlay: the live disciplines whose signal is fresh enough to inherit
    ///     the lead unasked. A discipline the user NAMED leads whether or not
    ///     it is in this set; this gate only bounds the fallback, which is how
    ///     a document left open last week stops quietly claiming the turn.
    public static func lead(
        focus: WorkspaceFocus?,
        live: [WorkspaceFocus],
        inPlay: Set<WorkspaceFocus>? = nil,
        strictFocus: Bool = false
    ) -> WorkspaceFocus? {
        // ASKED FOR AND PRESENT — it leads, stale or not. Naming it is the
        // freshest signal there is.
        if let focus, live.contains(focus) { return focus }
        // ASKED FOR AND ABSENT — strict mode would rather lead nothing than
        // hand the turn to a craft the user did not name.
        if strictFocus { return nil }
        let fresh = inPlay ?? Set(live)
        return live.first { fresh.contains($0) }
    }

    // MARK: - Which place leads

    /// The place that owns the lead discipline's full section.
    public static func leadPlace(
        among contributions: [Contribution],
        discipline: WorkspaceFocus?
    ) -> Contribution? {
        guard let discipline else { return nil }
        let eligible = contributions.filter { $0.discipline == discipline }
        if let named = eligible.first(where: \.wasNamed) { return named }
        // A full section beats a one-liner; among equals, the first in the caller's order.
        return eligible.first(where: { !$0.full.isEmpty }) ?? eligible.first
    }

    // MARK: - The ADHD case: a place still holds the lead though it is not frontmost

    /// The discipline the user was just doing REAL WORK in, kept live though
    /// another window now leads on-screen — the multitasking-agent feel:
    /// switching windows mid-request does not mean switching attention.
    /// Warranted by the ambient world, not a fixed clock: fresh `.activity`
    /// ledger evidence (a real read, not a mere activation/click-through),
    /// the conversational referent still pointing at that place, or this
    /// turn's own world snapshot naming it. The freshest warrant wins;
    /// naming a RIVAL place this turn beats stickiness outright, and an
    /// exact tie defers to ordinary frontmost arbitration rather than
    /// picking arbitrarily.
    public static func stickyLead(
        evidence: [AmbientPlace: FocusEvidence],
        contributions: [Contribution],
        referent: ResolvedReferent? = nil,
        world: AmbientWorld.Snapshot? = nil,
        now: Date = Date()
    ) -> WorkspaceFocus? {
        func warrant(_ place: AmbientPlace) -> Date? {
            if referent?.place == place { return now }
            if let id = place.application, world?.applicationID == id { return now }
            guard let stamp = evidence[place], stamp.kind == .activity else { return nil }
            return stamp.at
        }
        let warranted = contributions
            .filter(\.isLive)
            .compactMap { contribution -> (Contribution, Date)? in
                warrant(contribution.place).map { (contribution, $0) }
            }
            .sorted { $0.1 > $1.1 }
        guard let sticky = warranted.first,
              warranted.dropFirst().first?.1 != sticky.1
        else { return nil }
        guard !contributions.contains(where: { $0.wasNamed && $0.place != sticky.0.place })
        else { return nil }
        return sticky.0.discipline
    }

    // MARK: - The whole arbitration

    /// - Parameters: - contributions: every live place, in a stable caller-chosen order. - suppressFullSections: a place outside this arbitration owns the turn.
    public static func sections(
        focus: WorkspaceFocus?,
        contributions: [Contribution],
        writingInPlay: Bool = true,
        strictFocus: Bool = false,
        suppressFullSections: Bool = false,
        /// The place that owns the turn when full sections are suppressed, and
        /// what the user calls it. Resolving a display name needs the roster,
        /// which the prompt layer must not learn — so it arrives rendered.
        suppressingPlace: AmbientPlace? = nil,
        suppressingName: String? = nil
    ) -> PromptSections {
        let live = contributions.filter(\.isLive)

        // EVERY LIVE PLACE SPEAKS, at one volume or the other. Built first so
        // that no return path below can forget it — invariant 2 is a property
        // of this function, not a habit of its branches.
        func ambientLines(excluding lead: AmbientPlace?) -> [String] {
            live.compactMap { contribution in
                contribution.place == lead ? nil : contribution.ambient
            }
        }

        if suppressFullSections {
            return PromptSections(
                leadContext: [],
                ambientNotes: ambientLines(excluding: nil),
                leadPlace: suppressingPlace,
                liveWorld: .application(suppressingName))
        }

        // REGISTRY ORDER, then whatever else is live: a discipline the graph
        // does not rank still gets to lead rather than being dropped.
        let ranked = AmbientCapabilityIndexProvider.current.disciplines
            .map(WorkspaceFocus.init)
        let liveDisciplines = live.compactMap(\.discipline)
        let ordered = ranked.filter(liveDisciplines.contains)
            + liveDisciplines.filter { !ranked.contains($0) }
        let leadDiscipline = lead(
            focus: focus,
            live: ordered,
            inPlay: writingInPlay ? nil : Set(ordered.filter { $0 != .writing }),
            strictFocus: strictFocus)

        guard let owner = leadPlace(among: live, discipline: leadDiscipline) else {
            // NOTHING LEADS. Every live place still gets its line; what nobody
            // gets is the claim to be the work in front of the user.
            return PromptSections(
                leadContext: [],
                ambientNotes: ambientLines(excluding: nil),
                leadPlace: nil,
                liveWorld: .unled)
        }

        // A LEAD WITH NOTHING TO SHOW still leads — that is what a named but closed application looks like
        // SAME-PLACE FULLS MERGE.
        return PromptSections(
            leadContext: mergedFull(for: owner.place, among: live),
            ambientNotes: ambientLines(excluding: owner.place),
            leadPlace: owner.place,
            liveWorld: liveWorld(for: owner))
    }

    /// Every non-empty full section from observers of `place`, in caller
    /// order, without repeating an identical block.
    static func mergedFull(
        for place: AmbientPlace, among contributions: [Contribution]
    ) -> [String] {
        var merged: [String] = []
        for contribution in contributions where contribution.place == place {
            for section in contribution.full where !section.isEmpty && !merged.contains(section) {
                merged.append(section)
            }
        }
        return merged
    }

    static func liveWorld(for contribution: Contribution) -> LiveWorkWorld {
        let name = AmbientApplicationIndexProvider.current
            .registration(id: contribution.place.memoryToken)?.displayName
        guard let whole = contribution.liveDocumentIsWhole else {
            return .application(name)
        }
        return .document(name: name, whole: whole)
    }
}

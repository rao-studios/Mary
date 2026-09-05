//
//  PageRouter.swift
//  MaryPlugin
//
//  WHAT: One goal, one read, one row — arbitrated the way an utterance is arbitrated into
//        a Skill.
//  IN:   PageActor (press / fill / adjust / reveal), WebSearchRecipe (open a result)
//  OUT:  PageRouteArbitration — the row, or the sentence saying why not, and the record
//  PIN:  THE ABILITY ROSTER'S SHAPE, ON A PAGE. Mary decides which Skill an utterance
//        earns by scoring every candidate against typed evidence, admitting on a floor,
//        ranking on a vector, and giving every loser a disposition and a sentence. A page
//        had three ladders instead — one for pressing, one for results, one for native
//        windows — each a fixed sequence of ifs that returned a row or nil. They drifted,
//        they could not be compared, and a phrase that reached nothing left no record of
//        what it had been weighed against. This is that one arbitration.
//        PURE, AND THAT IS WHAT MAKES IT TESTABLE. No pixels, no pointer, no await: a
//        function of one read, one goal and one slate. Every measurement in
//        `PageRouteCalibrationTests` is this function over a recorded page.
//        EVERY ROW GETS A DECISION. Not a filtered list — "why wasn't it offered" is the
//        question a router exists to answer, and a row missing from the trace is a row
//        nobody can ask about.
//        A TIE IS A QUESTION. Two rows the evidence cannot separate stay two rows, named
//        back to the person. The one exception is a results page with nothing named to
//        match: "open the first one" is a real request, and refusing to choose there is a
//        worse answer than the top result.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse

public enum PageRouter {

    /// One read, arranged for the questions the router asks of every row.
    public struct PageRouteContext: Sendable {
        public var rows: [PageRosterRow]
        /// Group kinds by row ordinal — joined through the map's own membership lists,
        /// because a row's `groupID` never names the list it belongs to.
        var groupKindsByOrdinal: [Int: Set<String>]
        var overlayOrdinals: Set<Int>
        var furnitureBandOrdinals: Set<Int>
        public var hasOverlay: Bool
        /// The page laid at least one run of answers out as a group.
        public var hasResultGroup: Bool
        /// The reading called at least one row something to type into.
        public var hasFillableRow: Bool
        /// A real phrase was given to match by name — as opposed to the no-pick
        /// fallback, which has nothing to go on but the page's own structure.
        ///
        /// PIN: NAMING SOMETHING EXACTLY IS EVIDENCE THE MAP DOES NOT HAVE, and that
        /// rule is not `.openResult`'s to suspend. `.press`/`.fill`/`.adjust` all reach
        /// an ungrouped row on an exact match; `.openResult`'s own gate used to refuse
        /// one outright the moment the page held ANY row/card/list group elsewhere —
        /// measured live: a real, correctly split title ("Fred again.. | Boiler Room:
        /// London - YouTube") sat in an ungrouped band while an unrelated "related
        /// searches" suggestion panel nearby happened to be grouped as a card, and an
        /// exact pick naming the real title was refused rather than reaching it. The
        /// distinction this field draws is the one the rest of the router already
        /// makes everywhere else: guessing needs the page to vouch for a row; being
        /// told its name does not.
        public var hasPick: Bool
        /// The kind the goal (or the query behind it) named, when the page has rows of it.
        public var kindNamedInGoal: PageElementKind?

        func groupKinds(forOrdinal ordinal: Int) -> Set<String> {
            groupKindsByOrdinal[ordinal] ?? []
        }

        func isInOverlay(_ ordinal: Int) -> Bool { overlayOrdinals.contains(ordinal) }
        func isFurnitureBand(_ ordinal: Int) -> Bool {
            furnitureBandOrdinals.contains(ordinal)
        }
    }

    /// How close two meanings must be before the difference is noise rather than a
    /// verdict. `EmbeddingRouting.margin`'s number, in this lane's thousandths.
    static let semanticMargin = 40

    /// Which slot of the rank vector carries meaning, for this verb.
    static func isSemanticTerm(_ index: Int, verb: PageRouteVerb) -> Bool { index == 1 }

    /// A BAND OF SHORT LABELS IS A STRIP, NOT A LIST OF ANSWERS. Measured: a site's own
    /// "News · Videos · Web" row reads as a band of three short labels and was opened by
    /// page order.
    static let furnitureBandMinimum = 3

    // MARK: - The one pass

    /// Which row this goal reaches, and what every other row was.
    public static func arbitrate(
        goal rawGoal: String,
        verb: PageRouteVerb,
        roster: PageRoster,
        store: AmbientElementIndexStore = .shared,
        scope: AmbientElementScope? = nil
    ) -> PageRouteArbitration {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGoal = !goal.isEmpty
        let context = context(for: roster, verb: verb, goal: goal)
        let semantic = semanticScores(
            goal: goal, store: store, scope: scope ?? AffordanceSlatePublisher.browserScope)

        // 1 — the gate. Every row, one sentence each.
        var standings: [Int: Standing] = [:]
        var decisions: [Int: PageRouteDecision] = [:]
        var eligible: [PageRosterRow] = []
        var mismatched: [PageRosterRow] = []
        for row in context.rows {
            let standing = standing(of: row, verb: verb, in: context)
            standings[row.ordinal] = standing
            if let reason = standing.reason {
                if case .mismatched = standing { mismatched.append(row) }
                decisions[row.ordinal] = decision(
                    row, disposition: .ineligible, evidence: PageRouteEvidence(),
                    reason: reason)
            } else {
                eligible.append(row)
            }
        }

        // 2 — the naming ladder, once, over what is left.
        var lexical: [Int: (Int, PageRouteLexicalBasis)] = [:]
        if hasGoal, let reached = SpokenReference.reached(phrase: goal, among: eligible) {
            let points = lexicalScore(reached.rung)
            let named = basis(reached.rung)
            for index in reached.indices {
                lexical[eligible[index].ordinal] = (points, named)
            }
        }

        // 3 — the evidence, and the floor.
        var ranked: [(row: PageRosterRow, evidence: PageRouteEvidence, vector: [Int])] = []
        var notes: [Int: String] = [:]
        for row in eligible {
            let standing = standings[row.ordinal] ?? .offered
            let (lexicalPoints, lexicalBasis) = lexical[row.ordinal] ?? (0, .none)
            let structure = structureScore(row, verb: verb, in: context)
            notes[row.ordinal] = structure.note
            let evidence = PageRouteEvidence(
                lexical: lexicalPoints,
                lexicalBasis: lexicalBasis,
                semantic: Int((max(0, semantic[PageRowRule.identity(ordinal: row.ordinal)] ?? 0) * 1000).rounded()),
                affordance: affordanceScore(row, verb: verb, standing: standing),
                provenance: provenanceScore(row),
                structure: structure.score)
            guard !hasGoal || clearsFloor(evidence, standing: standing) else {
                decisions[row.ordinal] = decision(
                    row, disposition: .belowFloor, evidence: evidence,
                    reason: structure.note ?? belowFloorReason(
                        evidence, standing: standing, vectorized: !semantic.isEmpty))
                continue
            }
            ranked.append((
                row, evidence,
                rankVector(evidence, verb: verb, hasGoal: hasGoal)))
        }

        // 4 — the verdict.
        let trace = PageRouteTrace(goal: goal, verb: verb.word, decisions: [])
        guard !ranked.isEmpty else {
            // A GOAL THAT REACHED NOTHING ON A RESULTS PAGE IS NOT A DEAD END. The search
            // itself landed and the answers are there; what failed is the pick, and saying
            // so beats reporting a page full of results as empty.
            if hasGoal, case .openResult = verb,
               context.rows.contains(where: { standings[$0.ordinal]?.admits ?? false }) {
                var retry = arbitrate(
                    goal: "", verb: verb, roster: roster, store: store, scope: scope)
                retry.trace.goal = goal
                retry.trace.goalUnmatched = true
                return retry
            }
            // NAMING A REAL THING OF THE WRONG SORT deserves the sentence that says so:
            // "the search box" must not report as missing when a link says "search".
            if hasGoal, let refusal = mismatch(goal, verb: verb, among: mismatched) {
                return PageRouteArbitration(
                    refusal: refusal,
                    trace: finish(trace, decisions: decisions, rows: context.rows))
            }
            return PageRouteArbitration(
                refusal: .elementNotFound(hasGoal ? goal : "anything to open"),
                trace: finish(trace, decisions: decisions, rows: context.rows))
        }

        ranked.sort { ranksBefore(($0.vector, $0.row.ordinal), ($1.vector, $1.row.ordinal)) }
        let best = ranked[0].vector
        // A GENUINE TIE IS STILL A TIE, and two cosines a hair apart are not a decision.
        // `AffordanceResolver.tieBand`'s rule, in this lane's units: rows that agree on
        // every other term and sit within the margin of the leader's meaning are rivals,
        // because separating them would be reading noise as evidence.
        let winners = ranked.filter { entry in
            guard entry.vector.count == best.count else { return false }
            for (index, value) in entry.vector.enumerated() where value != best[index] {
                guard hasGoal, isSemanticTerm(index, verb: verb),
                      abs(best[index] - value) <= semanticMargin
                else { return false }
            }
            return true
        }

        // A tie on a results page with NO pick is not a question — page order answers it,
        // because "open the first one" is a real request and refusing to choose is worse
        // than the top result.
        let tied = winners.count > 1 && hasGoal
        let winning = Set(winners.map(\.row.ordinal))
        for entry in ranked {
            if tied, winning.contains(entry.row.ordinal) {
                decisions[entry.row.ordinal] = decision(
                    entry.row, disposition: .clarificationRequired, evidence: entry.evidence,
                    reason: "answers to \"\(goal)\" as well as \(winners.count - 1) other row\(winners.count == 2 ? "" : "s")")
            } else if entry.row.ordinal == ranked[0].row.ordinal {
                decisions[entry.row.ordinal] = decision(
                    entry.row, disposition: .selected, evidence: entry.evidence,
                    reason: selectedReason(entry.evidence, verb: verb, hasGoal: hasGoal))
            } else {
                decisions[entry.row.ordinal] = decision(
                    entry.row, disposition: .outranked, evidence: entry.evidence,
                    selectedAlternative: ranked[0].row.ordinal,
                    // WHAT THE PAGE SAID ABOUT IT beats "something else won": a row
                    // demoted for being promoted, or for sitting behind a dialog, is
                    // owed the fact rather than the outcome.
                    reason: notes[entry.row.ordinal]
                        ?? "\(shortened(ranked[0].row.label)) answered better")
            }
        }

        let finished = finish(trace, decisions: decisions, rows: context.rows)
        if tied {
            return PageRouteArbitration(
                refusal: .ambiguousElement(
                    phrase: goal,
                    rivals: winners.prefix(SpokenReference.spokenRivalLimit)
                        .map { shortened($0.row.label) }),
                trace: finished)
        }
        let winner = roster.elements.first { $0.ordinal == ranked[0].row.ordinal }
        return PageRouteArbitration(winner: winner, trace: finished)
    }

    // MARK: - The pieces

    /// Cosine per slate key, or nothing at all in degraded mode.
    static func semanticScores(
        goal: String, store: AmbientElementIndexStore, scope: AmbientElementScope
    ) -> [String: Float] {
        guard !goal.isEmpty,
              let index = store.index(for: scope),
              let query = store.queryVector(for: goal)
        else { return [:] }
        return index.semanticScores(forQueryVector: query)
    }

    static func context(
        for roster: PageRoster, verb: PageRouteVerb, goal: String
    ) -> PageRouteContext {
        let rows = roster.rows
        var kindsByOrdinal: [Int: Set<String>] = [:]
        var overlay: Set<Int> = []
        var furniture: Set<Int> = []
        let labelByOrdinal = Dictionary(
            rows.map { ($0.ordinal, $0.label) }, uniquingKeysWith: { first, _ in first })
        for group in roster.map.groups {
            for ordinal in group.memberOrdinals {
                kindsByOrdinal[ordinal, default: []].insert(group.kind)
            }
            if group.kind == "overlay" { overlay.formUnion(group.memberOrdinals) }
            guard group.kind == "band", group.memberOrdinals.count >= furnitureBandMinimum
            else { continue }
            let labels = group.memberOrdinals.compactMap { labelByOrdinal[$0] }
            let short = labels.filter { $0.count < minimumResultLabel }.count
            if short * 2 > labels.count { furniture.formUnion(group.memberOrdinals) }
        }
        // The kind a goal names is only meaningful where the page holds rows of it.
        let present = Set(rows.compactMap(\.kind))
        var named = PageElementKindDerivation.offeredKind(namedIn: goal, offering: present)
        if named == nil, case .openResult(let query) = verb {
            named = PageElementKindDerivation.offeredKind(namedIn: query, offering: present)
        }
        return PageRouteContext(
            rows: rows,
            groupKindsByOrdinal: kindsByOrdinal,
            overlayOrdinals: overlay,
            furnitureBandOrdinals: furniture,
            hasOverlay: !overlay.isEmpty,
            hasResultGroup: roster.map.groups.contains { resultGroupKinds.contains($0.kind) },
            hasFillableRow: rows.contains {
                $0.affordance == .fill || $0.kind == .field
            },
            hasPick: !goal.isEmpty,
            kindNamedInGoal: named)
    }

    /// The refusal for a goal that named a row this verb cannot use.
    static func mismatch(
        _ goal: String, verb: PageRouteVerb, among rows: [PageRosterRow]
    ) -> BrowserRefusal? {
        guard !rows.isEmpty,
              let reached = SpokenReference.reached(phrase: goal, among: rows),
              reached.indices.count == 1
        else { return nil }
        switch verb {
        case .fill: return .notFillable(goal)
        case .adjust: return .notAdjustable(goal)
        default: return nil
        }
    }

    static func clearsFloor(_ evidence: PageRouteEvidence, standing: Standing) -> Bool {
        let lexical = standing == .candidate ? candidateLexicalFloor : lexicalFloor
        let semantic = standing == .candidate ? candidateFloor : semanticFloor
        return evidence.lexical >= lexical || evidence.semantic >= semantic
    }

    static func belowFloorReason(
        _ evidence: PageRouteEvidence, standing: Standing, vectorized: Bool
    ) -> String {
        guard vectorized else { return "nothing in its name answers, and nothing vectorized" }
        if standing == .candidate {
            return "was named but not offered, and does not answer closely enough to reach past that"
        }
        return evidence.lexical > 0
            ? "only matches loosely"
            : "nothing about it answers"
    }

    static func selectedReason(
        _ evidence: PageRouteEvidence, verb: PageRouteVerb, hasGoal: Bool
    ) -> String {
        guard hasGoal else { return "is the page's own first answer" }
        switch evidence.lexicalBasis {
        case .ordinal: return "is at the position that was asked for"
        case .exact: return "is named exactly that"
        case .contained: return "is named that"
        case .allWords: return "carries every word that was said"
        case .kindOnly: return "is the only one of that kind"
        case .none: return "is the closest thing on the page to what was asked for"
        }
    }

    static func decision(
        _ row: PageRosterRow,
        disposition: PageRouteDisposition,
        evidence: PageRouteEvidence,
        selectedAlternative: Int? = nil,
        reason: String
    ) -> PageRouteDecision {
        PageRouteDecision(
            ordinal: row.ordinal,
            label: shortened(row.label),
            kind: row.kindWord,
            disposition: disposition,
            evidence: evidence,
            selectedAlternative: selectedAlternative,
            reason: reason)
    }

    /// Decisions in ordinal order, and never one short of the rows that were read.
    static func finish(
        _ trace: PageRouteTrace, decisions: [Int: PageRouteDecision], rows: [PageRosterRow]
    ) -> PageRouteTrace {
        var trace = trace
        trace.decisions = rows.compactMap { decisions[$0.ordinal] }
        return trace
    }

    static func shortened(_ label: String) -> String {
        ScreenElementResolver.shortened(label, limit: 60)
    }
}

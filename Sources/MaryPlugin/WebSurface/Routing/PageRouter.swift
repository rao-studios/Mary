//
//  PageRouter.swift
//  MaryPlugin
//
//  WHAT: One goal, one read, one row — arbitrated by the same procedure that
//        arbitrates an utterance into a Skill.
//  IN:   PageActor (press / fill / adjust / reveal), WebSearchRecipe (open a result)
//  OUT:  PageRouteArbitration — the row, or the sentence saying why not, and the record
//  PIN:  THE ABILITY ROSTER'S PROCEDURE, ON A PAGE — and now literally the same
//        code. A page had three ladders instead of an arbitration; they were
//        replaced by one pass shaped like the roster's, which was right and was
//        still a SECOND COPY: same phases, same vocabulary, nothing shared, so
//        the two could drift and neither could be read against the other. What
//        is left here is the DOMAIN — which rows may serve which verb, what
//        counts as evidence on a page, and the order those terms are compared
//        in. The procedure lives in `Arbitration`.
//        PURE, AND THAT IS WHAT MAKES IT TESTABLE. No pixels, no pointer, no
//        await: a function of one read, one goal and one slate.
//        A TIE IS A QUESTION. Two rows the evidence cannot separate stay two,
//        named back to the person. The one exception is a results page with
//        nothing named to match: "open the first one" is a real request, and
//        refusing to choose there is a worse answer than the top result.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse

/// The page, as a domain the shared arbitration can run.
public struct PageRouteDomain: ArbitrationDomain {

    public let verb: PageRouteVerb
    /// The kind the goal (or the query behind it) named, when the page has rows
    /// of it.
    public let kindNamedInGoal: PageElementKind?
    /// The reading called at least one row something to type into.
    public let hasFillableRow: Bool
    /// A real phrase was given to match by name — as opposed to the no-pick
    /// fallback, which has nothing to go on but the page's own structure.
    ///
    /// PIN: NAMING SOMETHING EXACTLY IS EVIDENCE THE MAP DOES NOT HAVE, and that
    /// rule is not `.openResult`'s to suspend. `.press`/`.fill`/`.adjust` all
    /// reach an ungrouped row on an exact match; `.openResult`'s own gate used to
    /// refuse one outright the moment the page held ANY row/card/list group
    /// elsewhere — measured live: a real, correctly split title ("Fred again.. |
    /// Boiler Room: London - YouTube") sat in an ungrouped band while an
    /// unrelated "related searches" suggestion panel nearby happened to be
    /// grouped as a card, and an exact pick naming the real title was refused
    /// rather than reaching it. The distinction this field draws is the one the
    /// rest of the router already makes everywhere else: guessing needs the page
    /// to vouch for a row; being told its name does not.
    public let hasPick: Bool

    public init(
        verb: PageRouteVerb,
        kindNamedInGoal: PageElementKind?,
        hasFillableRow: Bool,
        hasPick: Bool
    ) {
        self.verb = verb
        self.kindNamedInGoal = kindNamedInGoal
        self.hasFillableRow = hasFillableRow
        self.hasPick = hasPick
    }

    // MARK: - Identity

    public func identity(of row: PageRow) -> Int { row.ordinal }
    public func label(of row: PageRow) -> String { PageRouter.shortened(row.label) }
    public func kindWord(of row: PageRow) -> String { row.kindWord }

    // MARK: - The gate

    public func standing(of row: PageRow) -> ArbitrationStanding {
        PageRouter.standing(of: row, verb: verb, in: self)
    }

    // MARK: - The naming ladder

    public func lexical(
        goal: String, among rows: [PageRow]
    ) -> [Int: (points: Int, basis: String)] {
        guard let reached = SpokenReference.reached(phrase: goal, among: rows)
        else { return [:] }
        let points = PageRouter.lexicalScore(reached.rung)
        let basis = PageRouter.basis(reached.rung)
        var hits: [Int: (points: Int, basis: String)] = [:]
        for index in reached.indices {
            hits[rows[index].ordinal] = (points, basis.rawValue)
        }
        return hits
    }

    // MARK: - The evidence

    public func evidence(
        for row: PageRow,
        standing: ArbitrationStanding,
        lexical: (points: Int, basis: String)?,
        semantic: Int
    ) -> PageRouteEvidence {
        PageRouteEvidence(
            lexical: lexical?.points ?? 0,
            lexicalBasis: lexical.flatMap { PageRouteLexicalBasis(rawValue: $0.basis) } ?? .none,
            semantic: semantic,
            affordance: PageRouter.affordanceScore(row, verb: verb, standing: standing),
            provenance: PageRouter.provenanceScore(row),
            structure: PageRouter.structureScore(row, verb: verb, in: self).score)
    }

    public func rankVector(_ evidence: PageRouteEvidence, hasGoal: Bool) -> [Int] {
        PageRouter.rankVector(evidence, verb: verb, hasGoal: hasGoal)
    }

    /// `EmbeddingRouting.margin`'s number, in this lane's thousandths.
    public var tieMargin: Int { PageRouter.semanticMargin }
    /// Slot 1 of every rank vector this domain builds.
    public var semanticTermIndex: Int? { 1 }

    public func clearsFloor(
        _ evidence: PageRouteEvidence, standing: ArbitrationStanding
    ) -> Bool {
        PageRouter.clearsFloor(evidence, standing: standing)
    }

    // MARK: - The sentences

    public func sentence(
        for row: PageRow,
        evidence: PageRouteEvidence,
        disposition: ArbitrationDisposition,
        hasGoal: Bool
    ) -> String {
        switch disposition {
        case .selected:
            return PageRouter.selectedReason(evidence, hasGoal: hasGoal)
        case .belowFloor:
            return PageRouter.belowFloorReason(
                evidence, standing: standing(of: row), vectorized: evidence.semantic > 0)
        default:
            return "something else answered better"
        }
    }

    public func note(for row: PageRow) -> String? {
        PageRouter.structureScore(row, verb: verb, in: self).note
    }

    /// A GOAL THAT REACHED NOTHING ON A RESULTS PAGE IS NOT A DEAD END. The
    /// search itself landed and the answers are there; what failed is the pick,
    /// and saying so beats reporting a page full of results as empty.
    public func fallsBackWithNoGoal(_ rows: [PageRow]) -> Bool {
        if case .openResult = verb { return true }
        return false
    }
}

public enum PageRouter {

    /// How close two meanings must be before the difference is noise rather than
    /// a verdict. `EmbeddingRouting.margin`'s number, in this lane's thousandths.
    public static let semanticMargin = 40

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
        let rows = withEcho(roster.rows, verb: verb)
        let domain = domain(for: rows, verb: verb, goal: goal)
        let semantic = semanticScores(
            goal: goal, store: store, scope: scope ?? AffordanceSlatePublisher.browserScope)

        let result = Arbitration.run(
            domain,
            goal: goal,
            verb: verb.word,
            candidates: rows,
            semantic: Dictionary(
                semantic.compactMap { key, value -> (Int, Int)? in
                    guard let ordinal = PageRowRule.ordinal(fromIdentity: key) else { return nil }
                    return (ordinal, Int((max(0, value) * 1000).rounded()))
                },
                uniquingKeysWith: { first, _ in first }))

        if let winner = result.winner {
            return PageRouteArbitration(winner: winner, trace: result.trace)
        }
        if !result.rivals.isEmpty {
            return PageRouteArbitration(
                refusal: .ambiguousElement(
                    phrase: goal,
                    rivals: result.rivals.prefix(SpokenReference.spokenRivalLimit)
                        .map { shortened($0.label) }),
                trace: result.trace)
        }
        // NAMING A REAL THING OF THE WRONG SORT deserves the sentence that says
        // so: "the search box" must not report as missing when a link says
        // "search".
        let mismatched = rows.filter {
            if case .mismatched = domain.standing(of: $0) { return true }
            return false
        }
        if !goal.isEmpty, let refusal = mismatch(goal, verb: verb, among: mismatched) {
            return PageRouteArbitration(refusal: refusal, trace: result.trace)
        }
        return PageRouteArbitration(
            refusal: .elementNotFound(goal.isEmpty ? "anything to open" : goal),
            trace: result.trace)
    }

    // MARK: - The pieces

    /// THE ONE QUERY-DEPENDENT FACT, added where the query is known.
    ///
    /// PIN: EVERY OTHER FACT IS THE SEAL'S, decided once from the reading alone.
    /// This one cannot be: whether a row is the query said back is a question
    /// about what was ASKED, and the same page answers it differently for two
    /// different searches.
    static func withEcho(_ rows: [PageRow], verb: PageRouteVerb) -> [PageRow] {
        guard case .openResult(let query) = verb, !query.isEmpty else { return rows }
        return rows.map { row in
            guard RowFactsDerivation.isEcho(row.label, of: query) else { return row }
            var row = row
            row.facts.insert(.echoOfQuery)
            return row
        }
    }

    static func domain(
        for rows: [PageRow], verb: PageRouteVerb, goal: String
    ) -> PageRouteDomain {
        // The kind a goal names is only meaningful where the page holds rows of it.
        let present = Set(rows.compactMap(\.kind))
        var named = PageElementKindDerivation.offeredKind(namedIn: goal, offering: present)
        if named == nil, case .openResult(let query) = verb {
            named = PageElementKindDerivation.offeredKind(namedIn: query, offering: present)
        }
        return PageRouteDomain(
            verb: verb,
            kindNamedInGoal: named,
            hasFillableRow: rows.contains { $0.affordance == .fill || $0.kind == .field },
            hasPick: !goal.isEmpty)
    }

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

    /// The refusal for a goal that named a row this verb cannot use.
    static func mismatch(
        _ goal: String, verb: PageRouteVerb, among rows: [PageRow]
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

    static func clearsFloor(
        _ evidence: PageRouteEvidence, standing: ArbitrationStanding
    ) -> Bool {
        let lexical = standing == .candidate ? candidateLexicalFloor : lexicalFloor
        let semantic = standing == .candidate ? candidateFloor : semanticFloor
        return evidence.lexical >= lexical || evidence.semantic >= semantic
    }

    static func belowFloorReason(
        _ evidence: PageRouteEvidence, standing: ArbitrationStanding, vectorized: Bool
    ) -> String {
        guard vectorized else { return "nothing in its name answers, and nothing vectorized" }
        if standing == .candidate {
            return "was named but not offered, and does not answer closely enough to reach past that"
        }
        return evidence.lexical > 0
            ? "only matches loosely"
            : "nothing about it answers"
    }

    static func selectedReason(_ evidence: PageRouteEvidence, hasGoal: Bool) -> String {
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

    static func shortened(_ label: String) -> String {
        ScreenElementResolver.shortened(label, limit: 60)
    }
}

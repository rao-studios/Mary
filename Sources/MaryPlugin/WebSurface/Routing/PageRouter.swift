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

    /// THE PART OF THE PAGE THE GOAL NAMED, when it named one at all.
    ///
    /// PIN: A PLACE IS A GATE, NOT EVIDENCE. Measured across seven seeded pages:
    /// "the first link in the sidebar" on a page with no sidebar scored nothing
    /// on the naming ladder, fell through to meaning, and confidently opened a
    /// link in the body. A person who says WHERE has narrowed the page, and a row
    /// somewhere else is not a worse answer to that question — it is not an
    /// answer to it. Carried on the domain rather than asked at ranking time for
    /// the reason `kindNamedInGoal` is: it is one question about the GOAL, and
    /// the gate's job is to ask it of each ROW.
    /// `.some(nil)` MEANS "NAMED A PLACE THIS PAGE HAS NOT GOT", which refuses
    /// every row rather than quietly widening back to all of them.
    public let regionNamedInGoal: PageRegion??

    /// The goal named a THING, as opposed to counting one or naming nothing.
    /// See `PageRouter.clearsFloor`.
    public let goalNamesSomething: Bool

    /// THE SITE THE PERSON NAMED, when the page holds rows that lead there.
    ///
    /// PIN: RECOGNISED FROM THE PAGE, NEVER FROM A LIST. "Watch it on youtube"
    /// names a site, and nothing in this repository may hold a table of sites —
    /// so what makes "youtube" a site here is that a row on THIS page leads to
    /// one by that name. The page vouches for the word; the goal only has to
    /// contain it. A page whose rows lead nowhere named answers nil, and every
    /// row ranks exactly as it did before.
    public let siteNamedInGoal: String?

    public init(
        verb: PageRouteVerb,
        kindNamedInGoal: PageElementKind?,
        hasFillableRow: Bool,
        hasPick: Bool,
        regionNamedInGoal: PageRegion?? = nil,
        goalNamesSomething: Bool = false,
        siteNamedInGoal: String? = nil
    ) {
        self.regionNamedInGoal = regionNamedInGoal
        self.goalNamesSomething = goalNamesSomething
        self.siteNamedInGoal = siteNamedInGoal
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

        // A POSITION COUNTS WITHIN THE PAGE'S CONTENT; A NAME MAY REACH ANYWHERE.
        //
        // PIN: MEASURED ON THREE LEGS OF ROUND 0, ALL PICKING THE SAME ROW. "Open
        // the second one" and "open the third link" both selected a site's own
        // navigation strip — a row sitting in a form, offering nothing to press —
        // because counting ran over every ELIGIBLE row and the strip was second in
        // that list. Nobody counts a page's furniture when they say "the second
        // one"; they count the things the page is showing them. So a positional
        // rung recounts over content alone.
        // NAMING IS UNTOUCHED, and deliberately: "a person naming something is
        // evidence the map does not have" is this lane's rule, and someone who
        // says "Images" means the strip. Only `.ordinal` and `.kindOnly` — the
        // rungs that count rather than name — are narrowed.
        // A POSITION OVER NOTHING COUNTABLE IS A MISS, not a fallback to the wider
        // list: the same answer "the first video" already gets on a page holding
        // no videos.
        if reached.rung == .ordinal || reached.rung == .kindOnly {
            let content = rows.filter { PageRouter.countsForAPosition($0, verb: verb) }
            if content.count < rows.count {
                guard !content.isEmpty,
                      let again = SpokenReference.reached(phrase: goal, among: content)
                else { return [:] }
                return Self.hits(again, among: content)
            }
        }
        return Self.hits(reached, among: rows)
    }

    private static func hits(
        _ reached: (rung: SpokenReference.Rung, indices: [Int]), among rows: [PageRow]
    ) -> [Int: (points: Int, basis: String)] {
        let points = PageRouter.lexicalScore(reached.rung)
        let basis = PageRouter.basis(reached.rung)
        var hits: [Int: (points: Int, basis: String)] = [:]
        for index in reached.indices where rows.indices.contains(index) {
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
        PageRouter.clearsFloor(
            evidence, standing: standing, namedInGoal: goalNamesSomething)
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
        // A POSITION OVER NOTHING COUNTABLE IS A MISS, NOT THE PAGE'S FIRST
        // ANSWER. "The second one" on a page whose results the seal could not
        // count fell back to whatever ranked first — a shop's tile, measured in
        // round 14 — and was opened as if it were the second. A name that
        // matched nothing may take the page's own first answer; a number may
        // not, because the number was the whole request.
        if hasPick, !goalNamesSomething { return false }
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
        scope: AmbientElementScope? = nil,
        /// THE MEANING TERM, SUPPLIED RATHER THAN LOOKED UP — the one thing a
        /// replay cannot rebuild.
        ///
        /// PIN: A ROUTE IS A PURE FUNCTION OF A READ, AND THE MEANING SCORES ARE
        /// PART OF THE READ. They come from the turn's own element index, which
        /// is live per-turn state no offline run can reconstruct — so a replay
        /// that recomputed them was arguing a DIFFERENT read and calling the
        /// difference drift. Measured the first time any recording existed to
        /// replay: six of forty-three recorded routes disagreed, every one of
        /// them a row the meaning term had chosen. The recording already carries
        /// the score it used, per row; this is where it goes back in.
        semantic precomputed: [Int: Int]? = nil
    ) -> PageRouteArbitration {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = withEcho(roster.rows, verb: verb)
        let domain = domain(for: rows, verb: verb, goal: goal)
        // MEANING IS SCORED WITHOUT THE PLACE IN IT. See `PageRegion.removed`:
        // the region has already narrowed the pool, and the words that named it
        // describe no row.
        let meant = domain.regionNamedInGoal.flatMap { $0 }?.removed(from: goal) ?? goal
        let scored = precomputed ?? Dictionary(
            semanticScores(
                goal: meant, store: store,
                scope: scope ?? AffordanceSlatePublisher.browserScope
            ).compactMap { key, value -> (Int, Int)? in
                guard let ordinal = PageRowRule.ordinal(fromIdentity: key) else { return nil }
                return (ordinal, Int((max(0, value) * 1000).rounded()))
            },
            uniquingKeysWith: { first, _ in first })

        let result = Arbitration.run(
            domain,
            goal: goal,
            verb: verb.word,
            candidates: rows,
            semantic: scored)

        if let winner = result.winner {
            return PageRouteArbitration(winner: winner, trace: result.trace)
        }
        // TWO ROWS THAT LEAD TO THE SAME PLACE UNDER THE SAME NAME ARE ONE
        // ANSWER, NOT A QUESTION.
        //
        // PIN: "A TIE IS A QUESTION, NOT A COIN FLIP" IS ABOUT RIVALS, and these
        // are not rivals. MEASURED on a search engine that prints its top video
        // twice — once in a carousel, once in the list: identical title,
        // identical destination, and Mary asked which of the two the person
        // meant. Pressing either does the same thing, so asking is a question
        // with one answer. Same name AND same site, or it is a real ambiguity
        // and the refusal stands.
        if !result.rivals.isEmpty,
           let first = result.rivals.first, first.site != nil,
           result.rivals.allSatisfy({
               $0.site == first.site
                   && RowFactsDerivation.folded($0.label) == RowFactsDerivation.folded(first.label)
           }) {
            // THE RECORD SAYS WHAT HAPPENED. A trace still reporting a
            // clarification nobody was asked for would be evidence of a turn
            // that did not occur — the one thing a recording may never be.
            var trace = result.trace
            trace.decisions = trace.decisions.map { decision in
                guard decision.id == first.ordinal else { return decision }
                var decided = decision
                decided.disposition = .selected
                decided.reason = "the same page in the same place, twice"
                return decided
            }
            return PageRouteArbitration(winner: first, trace: trace)
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
        // THE PLACE THE GOAL NAMED. Asked of the page's own regions first, so a
        // page laid out in one column never has a "sidebar" to be asked about;
        // then of every region there is, so naming one this page lacks is a
        // refusal rather than a phrase nobody heard. See `regionNamedInGoal`.
        let regions = Set(rows.compactMap(\.region))
        let regionNamed: PageRegion??
        if regions.isEmpty {
            regionNamed = nil
        } else if let here = PageRegion.named(in: goal, among: regions) {
            regionNamed = .some(here)
        } else if PageRegion.named(in: goal, among: Set(PageRegion.allCases)) != nil {
            regionNamed = .some(nil)
        } else {
            regionNamed = nil
        }
        return PageRouteDomain(
            verb: verb,
            kindNamedInGoal: named,
            hasFillableRow: rows.contains { $0.affordance == .fill || $0.kind == .field },
            hasPick: !goal.isEmpty,
            regionNamedInGoal: regionNamed,
            // A POSITION IS NOT A NAME, and neither is an empty goal.
            goalNamesSomething: !goal.isEmpty
                && !PageElementKindDerivation.namesOnlyAPosition(goal),
            siteNamedInGoal: siteNamed(in: goal, verb: verb, among: rows))
    }

    /// The site a goal names, vouched for by the page's own rows.
    ///
    /// A site's spoken name is its host's words ("youtube", "ycombinator news"),
    /// and a goal names it when every one of those words is in the goal — so
    /// "watch fred again on youtube" names youtube, and "the video about
    /// youtube's history" names it too, which is the honest reading of a word
    /// somebody said out loud.
    static func siteNamed(
        in goal: String, verb: PageRouteVerb, among rows: [PageRow]
    ) -> String? {
        var asked = RowFactsDerivation.folded(goal)
        if case .openResult(let query) = verb, !query.isEmpty {
            asked += " " + RowFactsDerivation.folded(query)
        }
        let words = Set(asked.split(separator: " ").map(String.init))
        guard !words.isEmpty else { return nil }
        let sites = Set(rows.compactMap(\.site))
        return sites
            .filter { site in
                let parts = RowFactsDerivation.folded(site)
                    .split(separator: " ").map(String.init)
                return !parts.isEmpty && parts.allSatisfy(words.contains)
            }
            // The most specific name the goal covers: "google docs" over "google".
            .max { $0.count < $1.count }
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

    /// Is this row one of the things a person counts when they say "the second one"?
    ///
    /// PIN: THE PAGE'S CONTENT, NOT ITS CHROME. Furniture is what nobody counts —
    /// a toolbar, a form, a band of short labels, a strip of the site's own tabs,
    /// anything behind a dialog, and the query said back. AN ADVERT STILL COUNTS:
    /// it is a thing the person can see in the list, and skipping it would make
    /// Mary's "second" disagree with theirs. For `.openResult` the countable set
    /// is narrower still — the answers the page laid out — because that verb is
    /// only ever asked about a list of results.
    /// PIN: A FORM IS FURNITURE TO EVERY VERB BUT THE ONE THAT TYPES. Measured:
    /// "the search box at the top" scored nothing on a page whose search box was
    /// plainly there and plainly the only one — because the box sits in a form,
    /// forms are what nobody counts when they say "the second one", and the
    /// recount over content came back empty. That rule is right for pressing (a
    /// site's navigation strip lives in a form and is never the second result)
    /// and exactly backwards for filling, where the form IS the content: a
    /// person saying "the second field" means the second field of the form.
    /// The facts that keep a row out of a count. PUBLIC so the trip classifier
    /// counts exactly as the router does — two counts that differ are a
    /// verdict about nothing (round 9 measured five of them).
    /// A promoted row still COUNTS — an advert is a thing in the list, and a
    /// "second" that skipped it would disagree with the person's. It only
    /// ranks last among what was named.
    public static let uncountableForAPosition: RowFacts = [
        .inToolbar, .inForm, .inFurnitureBand, .separatedStrip,
        .behindOverlay, .echoOfQuery, .notDrawn,
    ]

    /// Whether a row is in the page's own column, as a count sees it.
    public static func inTheCountedColumn(_ region: PageRegion?) -> Bool {
        guard let region else { return true }
        return region == .main || region == .overlay
    }

    static func countsForAPosition(_ row: PageRow, verb: PageRouteVerb) -> Bool {
        var uncountable = uncountableForAPosition
        if verb == .fill { uncountable.remove(.inForm) }
        guard row.facts.isDisjoint(with: uncountable) else { return false }
        // AND ONLY THE PAGE'S OWN COLUMN. A site's header, its sidebars and its
        // footer are places a person names ("the search box at the top") and
        // never counts: measured on a results page, "the third link" reached
        // the site's logo, a skip-link and a related-search chip in the right
        // column, and the results were still to come. Only `main` — and an
        // overlay, which is what is in front of everything — is counted through.
        guard inTheCountedColumn(row.region) else { return false }
        if case .openResult = verb {
            // A RESULT IS SOMETHING THAT OPENS. A static text in a list-shaped
            // panel ("Search in: (Article) ×") was "the first one" — measured
            // on a site's own search page — because the pixel lane called the
            // panel a list and nothing asked whether the row could be pressed.
            return row.facts.contains(.inResultGroup) && row.affordance == .press
        }
        return true
    }

    static func clearsFloor(
        _ evidence: PageRouteEvidence,
        standing: ArbitrationStanding,
        namedInGoal: Bool = false
    ) -> Bool {
        let lexical = standing == .candidate ? candidateLexicalFloor : lexicalFloor
        let semantic = standing == .candidate ? candidateFloor : semanticFloor
        // MEANING ALONE ADMITS, AND IT HAS TO.
        //
        // PIN: TRIED AND MEASURED AND REVERTED, so nobody tries it again. Making
        // a NAMED goal require naming evidence — "a name must be answered by a
        // name" — looks right and is wrong: a page that spells its search box
        // "Search or ask a question" is reached by meaning and nothing else, and
        // `meaningCarriesACandidateTheWordsOnlyScatter` pins exactly that. The
        // real problem it was aimed at — a meaning-only match on this screen
        // beating a NAMED match one screen down that nobody had looked for — is
        // not a floor question at all. It belongs to the act, which now looks
        // further before it settles for a weak match. See
        // `BrowserEngine.lookingFurther`.
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

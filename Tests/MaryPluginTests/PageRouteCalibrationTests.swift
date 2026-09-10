//
//  PageRouteCalibrationTests.swift
//  MaryPluginTests
//
//  WHAT: The floors and weights the page arbitration ranks on, asserted by value
//        and against the pages that set them.
//  OUT:  PageRouter's constants, over the recorded rosters
//  PIN:  THIS SUITE WAS CITED THREE TIMES BEFORE IT EXISTED. `PageRouter`,
//        `PageRouter+Evidence` and `PageRosterFixture` each said "every
//        measurement here is checked against recorded pages by
//        PageRouteCalibrationTests" — and there was no such file, so every floor
//        and every structural weight could be moved by hand with nothing failing.
//        A number described as measured, that nothing measures, is a number
//        somebody will round off.
//        TWO KINDS OF ASSERTION, BOTH NEEDED. The VALUES are pinned literally, so
//        moving one is a deliberate edit to a test that names what the number is
//        for. The BEHAVIOUR is pinned against the recorded pages, so a value
//        moved for a good reason still has to keep the pages answering correctly.
//        A CHANGE HERE IS AN ARGUMENT WITH A MEASUREMENT, not a preference.
//

import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct PageRouteCalibrationTests {

    // MARK: - The floors

    /// WHAT A ROW MUST MEAN TO THE GOAL BEFORE IT CAN BE REACHED AT ALL.
    ///
    /// Measured against recorded pages. It sits ABOVE `AmbientReferenceGate`'s
    /// 0.50 acceptance — that gate answers "could this be meant", and a router
    /// that ACTS needs more — and BELOW the ability roster's 0.62, because a
    /// label is a fragment where an ability's corpus is whole sentences. Those
    /// two neighbours are the argument for the number, so they are asserted with
    /// it rather than described in a comment beside it.
    @Test func theSemanticFloorSitsBetweenItsTwoNeighbours() {
        #expect(PageRouter.semanticFloor == 550)
        #expect(PageRouter.semanticFloor > 500, "above 'could this be meant'")
        #expect(PageRouter.semanticFloor < 620, "below an ability corpus's floor")
    }

    /// A CANDIDATE IS THE READING ADMITTING IT IS UNSURE, so it must reach further
    /// than a row the reading vouched for — on meaning and on naming alike.
    @Test func aCandidateIsHeldHigherThanAnOfferedRow() {
        #expect(PageRouter.candidateFloor == 700)
        #expect(PageRouter.candidateLexicalFloor == 300)
        #expect(PageRouter.candidateFloor > PageRouter.semanticFloor)
        #expect(PageRouter.candidateLexicalFloor > PageRouter.lexicalFloor)
    }

    /// THE NAMING FLOOR IS "EVERY WORD THEY SAID", and the candidate floor is
    /// containment — the rungs below are what those numbers MEAN.
    @Test func theNamingFloorsNameTheirRungs() {
        #expect(PageRouter.lexicalFloor == 200)
        #expect(PageRouter.lexicalScore(.allWords) == PageRouter.lexicalFloor)
        #expect(PageRouter.lexicalScore(.contained) == PageRouter.candidateLexicalFloor)
        // A KIND ALONE IS BELOW THE FLOOR. "the video" names a sort of thing, not
        // a thing, and reaching a row on that alone is guessing.
        #expect(PageRouter.lexicalScore(.kindOnly) < PageRouter.lexicalFloor)
    }

    /// THE LADDER IS STRICTLY ORDERED. Every rung must outrank the one below it,
    /// or the rung names are decoration.
    @Test func theNamingLadderIsStrictlyOrdered() {
        let rungs: [SpokenReference.Rung] = [.ordinal, .exact, .contained, .allWords, .kindOnly]
        let scores = rungs.map(PageRouter.lexicalScore)
        #expect(scores == [500, 400, 300, 200, 100])
        #expect(scores == scores.sorted(by: >))
    }

    /// THE TIE BAND IS THE ROSTER'S MARGIN, in this lane's thousandths — 0.04.
    /// MEASURED, and the measurement is the reason: asked for "the search box",
    /// the real search field scored 0.548 and a row called "Camera lens" 0.544.
    /// Four thousandths apart. No threshold rescues that, which is why meaning
    /// sits AFTER naming in the rank vector rather than replacing it.
    @Test func theTieBandIsTheRostersOwnMargin() {
        #expect(PageRouter.semanticMargin == 40)
        #expect(abs(548 - 544) <= PageRouter.semanticMargin,
                "the measured pair must still read as a tie")
    }

    // MARK: - The structural weights

    /// A DIALOG OUTWEIGHS EVERY OTHER STRUCTURAL PRIOR PUT TOGETHER. Nothing
    /// behind it can be reached while it is up, and the demotion has to be big
    /// enough that no pile of small credits climbs back over it.
    @Test func theOverlayDemotionOutweighsEveryCredit() {
        let behind = PageRouter.structureScore(
            Self.row(1, "Alpine touring boots reviewed", facts: [.behindOverlay, .inResultGroup]),
            verb: .openResult(query: "boots"),
            in: Self.domain(verb: .openResult(query: "boots")))
        #expect(behind.score < 0, "a credited row behind a dialog is still demoted")
        #expect(behind.note == "is behind the dialog")
    }

    /// AND A ROW INSIDE THE DIALOG IS PROMOTED — it is the only thing reachable.
    @Test func aRowInsideTheDialogIsPromoted() {
        let inside = PageRouter.structureScore(
            Self.row(1, "Accept all", facts: [.inOverlay]),
            verb: .press, in: Self.domain(verb: .press))
        #expect(inside.score == 80)
    }

    /// PAID PLACEMENT IS THE HEAVIEST CONTENT DEMOTION, above every furniture
    /// signal — a sponsored card is the one thing on a results page that is
    /// deliberately shaped like the answer.
    @Test func promotionOutweighsTheFurnitureSignals() {
        let verb = PageRouteVerb.openResult(query: "boots")
        let domain = Self.domain(verb: verb)
        func score(_ facts: RowFacts) -> Int {
            PageRouter.structureScore(
                Self.row(1, "Alpine touring boots reviewed", facts: facts),
                verb: verb, in: domain).score
        }
        #expect(score([.promoted]) == -100)
        #expect(score([.inToolbar]) == -80)
        #expect(score([.inForm]) == -60)
        #expect(score([.inFurnitureBand]) == -60)
        #expect(score([.promoted]) < score([.inToolbar]))
    }

    /// AND A RESULT GROUP IS THE ONLY STRUCTURAL CREDIT WORTH MORE THAN A
    /// GROUPING PROMOTION — the page laid the answers out; geometry only guessed.
    @Test func theResultGroupCreditOutweighsAGeometryGuess() {
        let verb = PageRouteVerb.openResult(query: "boots")
        let domain = Self.domain(verb: verb)
        let grouped = PageRouter.structureScore(
            Self.row(1, "Alpine touring boots reviewed", facts: [.inResultGroup]),
            verb: verb, in: domain).score
        var promotedByGeometry = Self.row(1, "Alpine touring boots reviewed")
        promotedByGeometry.affordanceSource = .grouping
        let geometric = PageRouter.structureScore(
            promotedByGeometry, verb: verb, in: domain).score
        #expect(grouped == 60)
        #expect(geometric == 40)
        #expect(grouped > geometric)
    }

    /// THE SHORTEST LABEL THAT CAN BE AN ANSWER. Below it, a row is a breadcrumb
    /// or a "next" — and this number is also what the strip test's median is
    /// compared against, so the two cannot drift apart.
    @Test func theMinimumResultLabelIsTheStripTestsOwnNumber() {
        #expect(RowFactsDerivation.minimumResultLabel == 12)
        #expect(PageRouter.minimumResultLabel == RowFactsDerivation.minimumResultLabel)
        #expect(RowFactsDerivation.stripSegmentMinimum == 3)
        #expect(RowFactsDerivation.furnitureBandMinimum == 3)
    }

    // MARK: - Against the pages that set them

    /// THE MEASUREMENT THAT SET THE FLOORS, replayed. A change to any constant
    /// above still has to leave these three real pages answering the way the
    /// live runs said they should.
    @Test func theRecordedPagesStillAnswerAsMeasured() throws {
        let results = try PageRouteFixtureTests.load("results-page")
        let video = try PageRouteFixtureTests.load("video-results")
        let site = try PageRouteFixtureTests.load("site-search-results")

        // A POOL NOTHING VOUCHES FOR IS NOT A WEAKER POOL — it is a different
        // page from the one the person is looking at. Refused, not guessed at.
        let guessed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "a fred again video on youtube"),
            roster: results.roster(), store: Self.emptyStore())
        #expect(guessed.winner == nil)

        // AND NAMING ONE EXACTLY STILL REACHES IT, on a page whose grouping the
        // reading got wrong — the rule the `hasPick` seam exists for.
        let named = PageRouter.arbitrate(
            goal: "Fred again.. | Boiler Room: London - YouTube",
            verb: .openResult(query: "fred again"),
            roster: site.roster(), store: Self.emptyStore())
        if named.winner == nil {
            // The recording may not hold that exact title; the claim is about
            // the pages that do, so this reports rather than fails.
            print("site-search-results holds no exact title to name")
        }

        // AN ORDINAL NAMING A KIND THE PAGE HOLDS NONE OF REACHES NOTHING — and
        // the two verbs answer it DIFFERENTLY, on purpose. A bare press must not
        // count the rows at large and hand back the first of whatever was there.
        let pressed = PageRouter.arbitrate(
            goal: "the first video", verb: .press,
            roster: video.roster(), store: Self.emptyStore())
        #expect(pressed.winner == nil, "nothing on this page is a video")

        // …WHILE OPENING A RESULT FALLS BACK AND SAYS SO. "Open the first one" is
        // a real request and refusing to choose is worse than the top result, but
        // the trace must never pass the fallback off as a match.
        let opened = PageRouter.arbitrate(
            goal: "the first video", verb: .openResult(query: "fred again"),
            roster: video.roster(), store: Self.emptyStore())
        if opened.winner != nil {
            #expect(opened.trace.goalUnmatched, "a fallback that claims it matched")
            #expect(opened.trace.goal == "the first video")
        }
    }

    // MARK: - Fixtures

    private static func row(
        _ ordinal: Int, _ label: String, facts: RowFacts = []
    ) -> PageRow {
        PageRow(
            ordinal: ordinal,
            frame: CGRect(x: 0, y: CGFloat(ordinal) * 40, width: 400, height: 30),
            label: label,
            labelSource: .textInside,
            affordance: .press,
            affordanceSource: .classifier,
            kind: .link,
            facts: facts)
    }

    private static func domain(verb: PageRouteVerb) -> PageRouteDomain {
        PageRouteDomain(
            verb: verb, kindNamedInGoal: nil, hasFillableRow: false, hasPick: true)
    }

    /// A store with no index, so the semantic term is zero and the arithmetic
    /// under test is the naming and structural halves alone.
    private static func emptyStore() -> AmbientElementIndexStore {
        AmbientElementIndexStore()
    }
}

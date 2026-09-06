//
//  TripLayerTests.swift
//  MaryPluginTests
//
//  WHAT: Every layer can fail, fails for its own reason, and never for another's.
//  OUT:  TripLayer.judge, TripScoreboard
//  PIN:  THE CLASSIFIER IS THE PLAN'S ONE MOVING PART. A round is "fix the layer
//        the failure belongs to", so a classifier that blames the wrong layer
//        sends the next round's work to the wrong file — and the cheapest wrong
//        answer is always "the router did it", because the router is the thing
//        with a trace.
//        P AND R2 ARE TESTED AS A PAIR, WITH THE SAME ROUTE AND DIFFERENT ROWS.
//        The only difference between "the detector missed it" and "the router
//        passed it over" is whether a row answering the class was in the reading,
//        and that distinction is the whole reason a recording keeps the rows.
//        THE ORDER IS TESTED TOO. A leg wrong at two layers is owned by the
//        earlier one; everything after a wrong skill describes a turn nobody
//        asked for.
//

import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct TripLayerTests {

    // MARK: - Building a recording by hand

    static func row(
        _ ordinal: Int, facts: RowFacts = [], affordance: String = "press",
        kind: String? = nil, label: String = "a row"
    ) -> PageRosterFixture.Row {
        PageRosterFixture.Row(
            ordinal: ordinal, role: "", label: label,
            frame: [0, Double(ordinal) * 40, 400, 30], isEnabled: true,
            containerTrail: [], affordance: affordance,
            affordanceSource: "classifier", labelSource: "textInside",
            hints: [], groupID: nil, confidence: 0.8,
            facts: facts.rawValue, kind: kind)
    }

    static func page(_ rows: [PageRosterFixture.Row], classified: Bool = true)
        -> RecordedPageRead {
        RecordedPageRead(
            page: PageRosterFixture(
                pageFrame: [0, 0, 800, 600], rows: rows, groups: [],
                labeledFraction: 1, version: 2, classified: classified,
                readMilliseconds: 220),
            atMilliseconds: 100)
    }

    /// PIN: THE VERB IS SPELLED THE WAY A TRACE SPELLS IT. `PageRouteVerb.word`
    /// prints `openResult` as "result", and a helper that invented "openResult"
    /// was building recordings no live run can produce — so the tests over it
    /// were agreeing with a fixture rather than with the lane.
    static func route(
        goal: String = "the second one", verb: String = "result",
        selected: Int?, eligible: Int = 10, unmatched: Bool = false,
        basis: [Int: String] = [:], ordinals: [Int] = []
    ) -> RecordedRoute {
        RecordedRoute(
            goal: goal, verb: verb, eligibleCount: eligible,
            goalUnmatched: unmatched, selectedOrdinal: selected,
            decisions: ordinals.map { ordinal in
                RecordedRouteDecision(
                    ordinal: ordinal,
                    disposition: ordinal == selected ? "selected" : "candidate",
                    label: "a row", reason: "because", lexical: 0,
                    lexicalBasis: basis[ordinal] ?? "none", semantic: 0,
                    affordance: 0, provenance: 0, structure: 0, facts: 0)
            })
    }

    static func recording(
        pageReads: [RecordedPageRead] = [], routes: [RecordedRoute] = [],
        receipts: [RecordedReceipt] = [], routing: RecordedRouting? = nil,
        provider: (String, String)? = nil,
        before: RecordedAmbient? = nil, after: RecordedAmbient? = nil,
        speech: RecordedSpeech? = nil, landed: Bool = true,
        refusal: String? = nil, elapsed: Int = 100,
        acts: [RecordedAct] = []
    ) -> TripLegRecording {
        TripLegRecording(
            index: 0, say: "an utterance",
            routing: routing,
            providerApplicationID: provider?.0,
            providerRationale: provider?.1,
            ambientBefore: before, ambientAfter: after,
            pageReads: pageReads, routes: routes, acts: acts, receipts: receipts,
            ok: refusal == nil, landed: landed, refusal: refusal,
            speech: speech, elapsedMilliseconds: elapsed)
    }

    static func receipt(_ rank: String, landed: Bool = true) -> RecordedReceipt {
        RecordedReceipt(
            kind: "click", target: nil, delivery: "delivered",
            receipt: rank, landed: landed, spoken: "did it")
    }

    // MARK: - Nothing to say

    /// A LEG WITH NO EXPECTATIONS PASSES. Some legs exist only to put the
    /// machine somewhere, and a classifier that invented a verdict for them
    /// would fail rounds on legs nobody asserted anything about.
    @Test func aLegThatAssertsNothingPasses() {
        let judged = TripLayer.judge(
            leg: TripLeg(say: "go to wikipedia"), recording: Self.recording())
        #expect(judged.verdict == .passed)
        #expect(judged.layer == nil)
    }

    /// A PENDING LEG IS NEITHER PASSED NOR FAILED, and says which round it waits on.
    @Test func aPendingLegIsHeldOpen() {
        let judged = TripLayer.judge(
            leg: TripLeg(say: "switch to the other tab", pending: "round 3"),
            recording: Self.recording(landed: false))
        #expect(judged.verdict == .pending)
        #expect(judged.because == "waiting on round 3")
        #expect(judged.layer == nil)
    }

    // MARK: - R1

    @Test func reachingTheWrongSkillIsARoutingFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "mute the video",
                routing: TripRoutingExpectation(skill: "control_media")),
            recording: Self.recording(
                routing: RecordedRouting(uniqueSkill: "search_web")))
        #expect(judged.layer == .abilityRouting)
        #expect(judged.because?.contains("search_web") == true)
    }

    /// THE REPORTED DEFECT'S OWN SHAPE: the words reached the right skill and
    /// still cost a model round, which is where a sentence about a video meets a
    /// model holding only a search.
    @Test func noUniqueWinnerIsARoutingFailureWhenTheLaneWasClaimed() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "mute the video",
                routing: TripRoutingExpectation(skill: "control_media", lane: .confidence)),
            recording: Self.recording(routing: RecordedRouting(
                uniqueSkill: nil,
                topAffinities: ["control_media": 0.71, "search_web": 0.70])))
        #expect(judged.layer == .abilityRouting)
        #expect(judged.because?.contains("model round") == true)
        #expect(judged.because?.contains("control_media 0.71") == true)
    }

    @Test func theWrongIntentIsARoutingFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "what is this page about",
                routing: TripRoutingExpectation(skill: "read_page_text", intent: "ask")),
            recording: Self.recording(routing: RecordedRouting(
                intent: "operate", uniqueSkill: "read_page_text")))
        #expect(judged.layer == .abilityRouting)
        #expect(judged.because?.contains("operate") == true)
    }

    /// AN ARGUMENT THE LANE COULD NOT FILL. The confidence lane dispatches with
    /// no model round only when the arguments come out of the sentence.
    @Test func anUnfilledArgumentIsARoutingFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "look up alpine touring boots on the web",
                routing: TripRoutingExpectation(
                    skill: "search_web",
                    arguments: ["query": "alpine touring boots"])),
            recording: Self.recording(routing: RecordedRouting(
                uniqueSkill: "search_web", arguments: [:])))
        #expect(judged.layer == .abilityRouting)
        #expect(judged.because?.contains("did not fill query") == true)
    }

    /// AND ONE FILLED IN THE PERSON'S OWN WORDS PASSES, punctuation and all.
    @Test func anArgumentIsComparedFolded() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "look up alpine touring boots on the web",
                routing: TripRoutingExpectation(
                    skill: "search_web",
                    arguments: ["query": "alpine touring boots"])),
            recording: Self.recording(routing: RecordedRouting(
                uniqueSkill: "search_web",
                arguments: ["query": "Alpine touring boots!"])))
        #expect(judged.verdict == .passed)
    }

    /// A PROBE RUN HAS NO ROUTING TO JUDGE and must not be failed for it — it
    /// dispatches the binding directly and answers a different question.
    @Test func aRunWithNoRoutingRecordedIsNotFailedForIt() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "mute the video",
                routing: TripRoutingExpectation(skill: "control_media", lane: .confidence)),
            recording: Self.recording(routing: nil))
        #expect(judged.verdict == .passed)
    }

    // MARK: - A

    @Test func theWrongApplicationAnsweringIsAnAmbientFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "mute the video",
                provider: TripProviderExpectation(applicationID: "chrome")),
            recording: Self.recording(provider: ("safari", "focused")))
        #expect(judged.layer == .ambient)
        #expect(judged.because?.contains("safari answered") == true)
    }

    /// THE PIN IS A CORRECTION, and a correction that loses to whatever came
    /// forward is not one.
    @Test func theWrongRungChoosingIsAnAmbientFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "pause the video",
                provider: TripProviderExpectation(
                    applicationID: "chrome", rationale: .pinned)),
            recording: Self.recording(provider: ("chrome", "focused")))
        #expect(judged.layer == .ambient)
        #expect(judged.because?.contains("chosen by focused") == true)
    }

    /// INVARIANT 3: the browser is reachable from another surface, and the
    /// person's place is given back. The round-0 defect, stated as a check.
    @Test func stealingTheStageIsAnAmbientFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "mute the video",
                ambient: TripAmbientExpectation(frontAfter: .restored)),
            recording: Self.recording(
                before: RecordedAmbient(frontApplicationID: "xcode"),
                after: RecordedAmbient(frontApplicationID: "chrome")))
        #expect(judged.layer == .ambient)
        #expect(judged.because?.contains("left chrome in front") == true)
        #expect(judged.because?.contains("xcode") == true)
    }

    /// INVARIANT 2: a hand on the page makes every row Mary held wrong.
    @Test func aSurvivingSessionAfterANavigationIsAnAmbientFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the second one",
                ambient: TripAmbientExpectation(sessionInvalidated: true)),
            recording: Self.recording(after: RecordedAmbient(hasSession: true)))
        #expect(judged.layer == .ambient)
        #expect(judged.because?.contains("survived") == true)
    }

    // MARK: - P and R2, the pair

    /// THE READING HAD NOTHING TO PICK — a detector finding, and it belongs in
    /// VisionAX with a fixture.
    @Test func aReadingWithNoAnswerInItIsAPerceptionFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the first video",
                page: TripPageExpectation(
                    verb: .press,
                    winner: TripRowClass(kind: "video", ordinalWithinKind: 1))),
            recording: Self.recording(
                pageReads: [Self.page([Self.row(1, kind: "link"), Self.row(2, kind: "link")])],
                routes: [Self.route(verb: "press", selected: nil, ordinals: [1, 2])]))
        #expect(judged.layer == .perception)
        #expect(judged.because?.contains("no row in this reading") == true)
        #expect(judged.because?.contains("detector") == true)
    }

    /// THE SAME ROUTE, AND THE ANSWER WAS THERE. A routing finding, and it
    /// belongs in a row fact or a domain rule.
    @Test func anAnswerInTheReadingThatWasNotReachedIsARoutingFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the first video",
                page: TripPageExpectation(
                    verb: .press,
                    winner: TripRowClass(kind: "video", ordinalWithinKind: 1))),
            recording: Self.recording(
                pageReads: [Self.page([Self.row(1, kind: "link"), Self.row(2, kind: "video")])],
                routes: [Self.route(verb: "press", selected: nil, ordinals: [1, 2])]))
        #expect(judged.layer == .pageRouting)
        #expect(judged.because?.contains("reached nothing") == true)
        #expect(judged.because?.contains("1 row") == true)
    }

    /// THE ECHO AND THE STRIP, NAMED. What a wrong row IS is the sentence the
    /// next round acts on.
    @Test func reachingAForbiddenRowNamesTheFactThatDisqualifiedIt() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the second one",
                page: TripPageExpectation(
                    verb: .openResult,
                    winner: TripRowClass(
                        facts: ["inResultGroup"],
                        factsAbsent: ["echoOfQuery", "separatedStrip"]))),
            recording: Self.recording(
                pageReads: [Self.page([
                    Self.row(1, facts: [.inResultGroup, .echoOfQuery]),
                    Self.row(2, facts: [.inResultGroup]),
                ])],
                routes: [Self.route(selected: 1, ordinals: [1, 2])]))
        #expect(judged.layer == .pageRouting)
        #expect(judged.because?.contains("echoOfQuery") == true)
    }

    /// AND THE RIGHT ROW PASSES, counted within what the rest of the class admits.
    @Test func theSecondOfWhatTheClassAdmitsIsTheSecondResult() {
        let leg = TripLeg(
            say: "open the second one",
            page: TripPageExpectation(
                verb: .openResult,
                winner: TripRowClass(
                    facts: ["inResultGroup"], factsAbsent: ["echoOfQuery"],
                    ordinalWithinKind: 2)))
        // Row 1 is the query said back, so the answers are rows 2 and 3 — and
        // the SECOND answer is row 3, not row 2.
        let page = Self.page([
            Self.row(1, facts: [.inResultGroup, .echoOfQuery]),
            Self.row(2, facts: [.inResultGroup]),
            Self.row(3, facts: [.inResultGroup]),
        ])
        let reached = TripLayer.judge(
            leg: leg,
            recording: Self.recording(
                pageReads: [page], routes: [Self.route(selected: 3, ordinals: [1, 2, 3])]))
        #expect(reached.verdict == .passed)

        let missed = TripLayer.judge(
            leg: leg,
            recording: Self.recording(
                pageReads: [page], routes: [Self.route(selected: 2, ordinals: [1, 2, 3])]))
        #expect(missed.layer == .pageRouting)
        #expect(missed.because?.contains("number 1 of its kind, not 2") == true)
    }

    /// A FALLBACK THAT CLAIMS IT MATCHED IS ITS OWN FAILURE. `.openResult` may
    /// fall back to the page's first answer; it may not say it found what was asked.
    @Test func aFallbackClaimingAMatchIsARoutingFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the first video",
                page: TripPageExpectation(
                    refusal: .elementNotFound, goalUnmatched: true)),
            recording: Self.recording(
                pageReads: [Self.page([Self.row(1)])],
                routes: [Self.route(selected: 1, unmatched: false, ordinals: [1])]))
        #expect(judged.layer == .pageRouting)
    }

    /// A REFUSAL FOR WANT OF ROWS IS A DIFFERENT FINDING FROM A CONSIDERED ONE.
    @Test func tooFewEligibleRowsIsNamedAsSuch() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the first video",
                page: TripPageExpectation(
                    refusal: .elementNotFound, minimumEligible: 5)),
            recording: Self.recording(
                pageReads: [Self.page([Self.row(1)])],
                routes: [Self.route(selected: nil, eligible: 1, ordinals: [1])],
                landed: false, refusal: "elementNotFound"))
        #expect(judged.layer == .pageRouting)
        #expect(judged.because?.contains("want of rows") == true)
    }

    /// THE NAMING RUNG IS PART OF THE CLASS. A position the person spoke must be
    /// reached BY that position, not stumbled onto by meaning.
    @Test func theWrongNamingRungIsARoutingFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the third link",
                page: TripPageExpectation(
                    verb: .press,
                    winner: TripRowClass(lexicalBasis: "ordinal"))),
            recording: Self.recording(
                pageReads: [Self.page([Self.row(1)])],
                routes: [Self.route(
                    verb: "press", selected: 1, basis: [1: "contained"], ordinals: [1])]))
        #expect(judged.layer == .pageRouting)
        #expect(judged.because?.contains("contained") == true)
    }

    /// A LEG NAMES WHICH ROUTE IT MEANS, AND A SEARCH ROUTES TWICE.
    ///
    /// PIN: MEASURED LIVE. A search navigates, reads, arbitrates `.openResult`
    /// to choose an answer, then presses it — and pressing arbitrates AGAIN with
    /// `.press`. Judging "the last route" reported the leg as routing with the
    /// wrong verb, which is the classifier blaming the router for its own
    /// reading.
    @Test func aLegNamingAVerbIsJudgedAgainstThatRoute() {
        let page = Self.page([
            Self.row(1, facts: [.inResultGroup]),
            Self.row(2, facts: [.inResultGroup]),
        ])
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "look it up",
                page: TripPageExpectation(
                    verb: .openResult,
                    winner: TripRowClass(facts: ["inResultGroup"], ordinalWithinKind: 1))),
            recording: Self.recording(
                pageReads: [page],
                routes: [
                    Self.route(verb: "result", selected: 1, ordinals: [1, 2]),
                    // The inner press, which is not what the leg is about.
                    Self.route(verb: "press", selected: 2, ordinals: [1, 2]),
                ]))
        #expect(judged.verdict == .passed)
    }

    /// AND WITH NO VERB NAMED, THE LAST ROUTE IS STILL THE ANSWER.
    @Test func aLegNamingNoVerbIsJudgedAgainstTheLastRoute() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "press it",
                page: TripPageExpectation(
                    winner: TripRowClass(facts: ["inResultGroup"]))),
            recording: Self.recording(
                pageReads: [Self.page([Self.row(1), Self.row(2, facts: [.inResultGroup])])],
                routes: [
                    Self.route(verb: "result", selected: 2, ordinals: [1, 2]),
                    Self.route(verb: "press", selected: 1, ordinals: [1, 2]),
                ]))
        #expect(judged.layer == .pageRouting)
    }

    // MARK: - E

    /// THE MEDIA LANE'S KNOWN DEFECT: a proven mute reporting `landed: false`,
    /// which is what sent the turn back for a second attempt.
    @Test func aProvenActThatDoesNotLandIsAnExecutionFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "mute the video",
                engine: TripEngineExpectation(receipt: .mediaState, landed: true)),
            recording: Self.recording(
                receipts: [Self.receipt("mediaState", landed: false)], landed: false))
        #expect(judged.layer == .execution)
        #expect(judged.because?.contains("did not land") == true)
    }

    /// A WEAKER RECEIPT THAN THE ONE OWED. "The page changed" is a sign and
    /// never proof.
    @Test func aWeakerReceiptThanTheOneOwedIsAnExecutionFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the second one",
                engine: TripEngineExpectation(receipt: .navigation, landed: true)),
            recording: Self.recording(receipts: [Self.receipt("rosterChanged")]))
        #expect(judged.layer == .execution)
        #expect(judged.because?.contains("rosterChanged") == true)
    }

    @Test func theWrongRefusalIsAnExecutionFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "pause the video",
                engine: TripEngineExpectation(refusal: .controlsNotFound)),
            recording: Self.recording(landed: false, refusal: "pageNotVisible"))
        #expect(judged.layer == .execution)
        #expect(judged.because?.contains("pageNotVisible") == true)
    }

    // MARK: - S

    /// THE OTHER REPORTED DEFECT: the read ran and Mary said nothing.
    @Test func aTurnThatEndsInSilenceIsASpeechFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "what is this page about",
                speech: TripSpeechExpectation(silence: "forbidden")),
            recording: Self.recording(
                speech: RecordedSpeech(spoken: "", readRoutes: ["chainStalled"])))
        #expect(judged.layer == .speech)
        #expect(judged.because?.contains("said nothing") == true)
        #expect(judged.because?.contains("chainStalled") == true)
    }

    /// AND A READ THAT WAS DROPPED FOR RESTATING is visible as itself.
    @Test func aForbiddenLedgerRouteIsASpeechFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "what is this page about",
                speech: TripSpeechExpectation(ledgerNot: ["droppedAsRestating"])),
            recording: Self.recording(speech: RecordedSpeech(
                spoken: "Here you go.", spokeInTurn: true,
                readRoutes: ["droppedAsRestating"])))
        #expect(judged.layer == .speech)
        #expect(judged.because?.contains("droppedAsRestating") == true)
    }

    // MARK: - T

    @Test func passingSlowlyIsATimingFailure() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the second one",
                engine: TripEngineExpectation(receipt: .navigation, landed: true, budgetMs: 3000)),
            recording: Self.recording(
                receipts: [Self.receipt("navigation")], elapsed: 9100))
        #expect(judged.layer == .timing)
        #expect(judged.because?.contains("9100ms") == true)
        #expect(judged.because?.contains("3000ms") == true)
    }

    // MARK: - The order

    /// A LEG WRONG AT TWO LAYERS IS OWNED BY THE EARLIER ONE. Everything after a
    /// wrong skill describes a turn nobody asked for, so blaming the receipt
    /// would send the round to fix an executor that did what it was told.
    @Test func theEarliestFailingLayerOwnsTheLeg() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "mute the video",
                routing: TripRoutingExpectation(skill: "control_media"),
                engine: TripEngineExpectation(receipt: .mediaState, landed: true),
                speech: TripSpeechExpectation(silence: "forbidden")),
            recording: Self.recording(
                receipts: [],
                routing: RecordedRouting(uniqueSkill: "search_web"),
                speech: RecordedSpeech(spoken: ""), landed: false))
        #expect(judged.layer == .abilityRouting)
    }

    /// AND AMBIENT COMES BEFORE THE PAGE: the wrong browser's page routed
    /// perfectly is still the wrong browser.
    @Test func ambientOutranksThePage() {
        let judged = TripLayer.judge(
            leg: TripLeg(
                say: "open the second one",
                provider: TripProviderExpectation(applicationID: "chrome"),
                page: TripPageExpectation(
                    verb: .openResult, winner: TripRowClass(facts: ["inResultGroup"]))),
            recording: Self.recording(
                pageReads: [Self.page([Self.row(1)])],
                routes: [Self.route(selected: 1, ordinals: [1])],
                provider: ("safari", "focused")))
        #expect(judged.layer == .ambient)
    }

    // MARK: - The scoreboard

    @Test func theScoreboardCountsByCategoryAndLayer() {
        let recordings = [
            TripRecording(
                tripID: "a", category: "search", runner: "probe", round: "0",
                legs: [
                    TripLegRecording(index: 0, say: "x", verdict: .passed),
                    TripLegRecording(
                        index: 1, say: "y", verdict: .failed, layer: .pageRouting),
                ]),
            TripRecording(
                tripID: "b", category: "media", runner: "probe", round: "0",
                legs: [
                    TripLegRecording(
                        index: 0, say: "z", verdict: .failed, layer: .execution),
                    TripLegRecording(index: 1, say: "w", verdict: .pending),
                ]),
        ]
        let board = TripScoreboard.score(recordings)
        #expect(board.rows.map(\.category) == ["media", "search"])
        #expect(board.totals.passed == 1)
        #expect(board.totals.failed == 2)
        #expect(board.totals.pending == 1)
        #expect(board.totals.byLayer[.pageRouting] == 1)
        #expect(board.totals.byLayer[.execution] == 1)
        // PENDING IS NEITHER: the rate is of the legs that could run.
        #expect(board.rows.first { $0.category == "media" }?.rate == 0)
        #expect(board.rows.first { $0.category == "search" }?.rate == 0.5)
    }

    /// A ROUND'S SECTION IS REWRITTEN IN PLACE, so re-running round 0 does not
    /// leave the document holding two accounts of it.
    @Test func aRoundsSectionIsRewrittenRatherThanAppended() {
        let board = TripScoreboard.score([
            TripRecording(
                tripID: "a", category: "search", runner: "probe", round: "0",
                legs: [TripLegRecording(index: 0, say: "x", verdict: .passed)]),
        ])
        let document = """
        # The trips

        Some prose.

        ### Round 0 — 2020-01-01

        | old | table |

        ## Something after
        """
        let merged = board.merged(into: document)
        #expect(merged.components(separatedBy: "### Round 0").count == 2)
        #expect(merged.contains("## Something after"))
        #expect(!merged.contains("| old | table |"))
        #expect(merged.contains("Some prose."))

        // And a round nobody has written yet is appended whole.
        var later = board
        later.round = "1"
        let appended = later.merged(into: merged)
        #expect(appended.contains("### Round 0"))
        #expect(appended.contains("### Round 1"))
    }

    /// A ROUND THAT COULD NOT RUN IS NOT A ROUND THAT PASSED.
    ///
    /// PIN: MEASURED ON THE FIRST LIVE RUN. Seven trips came back unstageable
    /// for want of an address, one leg passed, and the scoreboard reported the
    /// exit criterion MET. A rate computed over the legs that ran says nothing
    /// about the ones that could not.
    @Test func aRoundThatBarelyRanDoesNotMeetTheCriterion() {
        let board = TripScoreboard.score([
            TripRecording(
                tripID: "a", category: "read", runner: "probe", round: "0",
                legs: [
                    TripLegRecording(index: 0, say: "x", verdict: .passed),
                    TripLegRecording(index: 1, say: "y", verdict: .unstageable),
                    TripLegRecording(index: 2, say: "z", verdict: .unstageable),
                ]),
        ])
        let (met, because) = board.meetsExitCriterion()
        #expect(!met)
        #expect(because.contains { $0.contains("unstageable against") })
        #expect(because.contains { $0.contains("no recordings at all for") })
        #expect(board.markdown().contains("Exit criterion not met"))
    }

    /// AND A CATEGORY THAT RAN NOTHING IS NAMED, even when everything else did.
    @Test func aSilentCategoryIsNamed() {
        let board = TripScoreboard.score([
            TripRecording(
                tripID: "a", category: "read", runner: "probe", round: "0",
                legs: [TripLegRecording(index: 0, say: "x", verdict: .passed)]),
            TripRecording(
                tripID: "b", category: "tabs", runner: "probe", round: "0",
                legs: [TripLegRecording(index: 0, say: "y", verdict: .pending)]),
        ])
        #expect(board.meetsExitCriterion().because.contains { $0.contains("no leg ran in tabs") })
    }

    /// THE EXIT CRITERION IS A CALCULATION, not a feeling about the round.
    @Test func theExitCriterionNamesWhatIsStillWrong() {
        let board = TripScoreboard.score([
            TripRecording(
                tripID: "a", category: "search", runner: "probe", round: "2",
                legs: [
                    TripLegRecording(index: 0, say: "x", verdict: .passed),
                    TripLegRecording(
                        index: 1, say: "y", verdict: .failed, layer: .pageRouting),
                ]),
            TripRecording(
                tripID: "b", category: "context", runner: "turn", round: "2",
                legs: [
                    TripLegRecording(
                        index: 0, say: "z", verdict: .failed, layer: .ambient),
                ]),
        ])
        let (met, because) = board.meetsExitCriterion()
        #expect(!met)
        #expect(because.contains { $0.contains("search at 50%") })
        #expect(because.contains { $0.contains("context has 1 failing") })
        #expect(because.contains { $0.contains("page-routing failure") })
        #expect(board.markdown().contains("Exit criterion not met"))
    }
}

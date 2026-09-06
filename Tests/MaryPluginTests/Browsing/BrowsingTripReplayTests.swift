//
//  BrowsingTripReplayTests.swift
//  MaryPluginTests
//
//  WHAT: Recorded trips, re-argued offline — the routing decisions a live round
//        made, kept arithmetic afterwards.
//  IN:   Tests/MaryPluginTests/Fixtures/Trips/**/*.recording.json
//  OUT:  the R2 regression net
//  PIN:  A ROUTE IS A PURE FUNCTION OF A READ, AND A RECORDING IS THE READ.
//        Every wrong press this lane has made was made against a live page
//        nobody could put in a test — the strip that won on page order, the echo
//        that won on word cover, the region picker that won for being first.
//        Recorded, each becomes arithmetic. This is `PageRouteFixtureTests`
//        generalized: instead of three pages somebody remembered to save, every
//        page a round drove through is replayed with the goal it was actually
//        given, and the answer compared with the one the live run got.
//        WHAT IT REPLAYS IS THE ROUTE, NOT THE ACT. A recording is enough to
//        re-argue a routing decision exactly, because the router reads only the
//        roster and the goal. It is NOT enough to replay an act: a receipt is a
//        comparison of two readings taken around a press that a replay does not
//        perform. So the acts are checked as expectations against what the live
//        run recorded, and the two recovery cases that genuinely need a fake — a
//        page that never settles, a stage that stops holding focus — are engine
//        tests with fakes rather than machinery nothing else uses.
//        DRIFT IS REPORTED, NOT SILENTLY REPASSED. A recording whose route
//        changes on identical evidence is the whole signal this file exists for.
//

import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct BrowsingTripReplayTests {

    static var tripsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Trips", isDirectory: true)
    }

    /// The verb a recorded route was argued with, back from its own words.
    ///
    /// PIN: THROUGH `TripRouteVerb.named(traceWord:)`, which owns the one place
    /// the trace's "result" and the trip's `openResult` are reconciled.
    static func verb(_ recorded: RecordedRoute) -> PageRouteVerb? {
        switch TripRouteVerb.named(traceWord: recorded.verb) {
        case .press: return .press
        case .fill: return .fill
        case .adjust: return .adjust
        case .reveal: return .reveal
        case .openResult: return .openResult(query: recorded.query ?? "")
        case nil: return nil
        }
    }

    /// The meaning term as the live run scored it, per row.
    static func semantic(_ recorded: RecordedRoute) -> [Int: Int] {
        Dictionary(
            recorded.decisions.map { ($0.ordinal, $0.semantic) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: - The corpus of recordings

    /// EVERY RECORDING IS ONE WE CAN READ. Same rule as the trips, and the same
    /// reason: a corpus that silently shrinks always passes.
    @Test func everyRecordingIsOneWeCanRead() {
        let found = TripRecording.all(under: Self.tripsRoot)
        let named = found.unreadable
            .map { "\($0.url.lastPathComponent): \($0.problem)" }
            .joined(separator: "; ")
        #expect(found.unreadable.isEmpty, "\(named)")
    }

    /// A RECORDED ROUTE ANSWERS THE SAME WAY ON THE SAME EVIDENCE.
    ///
    /// PIN: THE CONSTANTS ARE WHAT THIS CATCHES. Move a floor or a structural
    /// weight in `PageRouter` by hand and a recorded page starts answering
    /// differently against the identical read — which is the one thing a
    /// calibration comment cannot notice.
    @Test func everyRecordedRouteAnswersAsItDid() {
        let found = TripRecording.all(under: Self.tripsRoot)
        // NOTHING TO REPLAY IS NOT A PASS TO BE PROUD OF, and it is not a
        // failure either: recordings arrive with a live round.
        guard !found.recordings.isEmpty else { return }

        var drift: [String] = []
        for (url, recording) in found.recordings {
            for leg in recording.legs {
                // THE READ THE ROUTE WAS ARGUED AGAINST, WHICH IS THE FIRST.
                //
                // PIN: A LEG READS THE PAGE TWICE — once to route, once after
                // the act to prove it — and this took the LAST, so every route
                // was re-argued against the page that came AFTER the press. On a
                // leg that navigated, that is a different page entirely, and the
                // net reported the difference as drift in the router. Measured
                // the first time any recording existed to replay: four of the
                // six reports were this, including one comparing a search
                // results page with the article it had opened.
                guard let page = leg.pageReads.first?.page else { continue }
                let roster = page.roster()
                for recorded in leg.routes {
                    guard let verb = Self.verb(recorded) else { continue }
                    let again = PageRouter.arbitrate(
                        goal: recorded.goal, verb: verb, roster: roster,
                        // THE MEANING SCORES THE LIVE ROUTE USED. See
                        // `PageRouter.arbitrate(semantic:)`: they are part of the
                        // read, not something a replay can recompute, and
                        // recomputing them was the whole of the first drift
                        // report this net ever produced.
                        semantic: Self.semantic(recorded))
                    let now = again.winner?.ordinal
                    guard now != recorded.selectedOrdinal else { continue }
                    drift.append(
                        "\(url.lastPathComponent) leg \(leg.index) "
                            + "\"\(recorded.goal)\" (\(recorded.verb)) reached "
                            + "\(now.map(String.init) ?? "nothing") on replay, "
                            + "\(recorded.selectedOrdinal.map(String.init) ?? "nothing") when recorded")
                }
            }
        }
        let named = drift.joined(separator: "\n")
        #expect(drift.isEmpty, "\(named)")
    }

    /// AND THE ROW IT REACHES STILL ANSWERS THE TRIP'S CLASS. Drift is one
    /// signal; the other is the leg's own expectation, re-checked against the
    /// replayed decision rather than against what the live run happened to do.
    @Test func everyRecordedLegStillMeetsItsPageExpectation() throws {
        let recordings = TripRecording.all(under: Self.tripsRoot).recordings
        guard !recordings.isEmpty else { return }
        let trips = Dictionary(
            BrowsingTrip.all(under: Self.tripsRoot).map { ($0.trip.id, $0.trip) },
            uniquingKeysWith: { first, _ in first })

        var wrong: [String] = []
        var detail: [String: String] = [:]
        for (url, recording) in recordings {
            guard let trip = trips[recording.tripID] else {
                wrong.append("\(url.lastPathComponent) records a trip that is gone")
                continue
            }
            for leg in recording.legs {
                guard leg.index < trip.legs.count else { continue }
                let expectation = trip.legs[leg.index]
                guard expectation.page != nil else { continue }
                let judged = TripLayer.judge(leg: expectation, recording: leg)
                guard judged.layer == .pageRouting || judged.layer == .perception
                else { continue }
                // KEYED ON WHAT DOES NOT CHURN. The sentence carries a live row
                // count ("though 96 row(s) in the reading answer the class"),
                // which changes every time a round re-records — so a ledger keyed
                // on it would report four regressions and four fixes each round
                // and mean nothing. The trip, the leg and the LAYER are the
                // finding; the sentence is how it reads.
                wrong.append("\(recording.tripID)[\(leg.index)] \(judged.layer?.rawValue ?? "")")
                detail["\(recording.tripID)[\(leg.index)]"] = judged.because ?? ""
            }
        }
        // A TWO-WAY LEDGER, THE SAME SHAPE AS THE ROUTING ONE.
        //
        // PIN: THESE ARE THE ROUND'S OWN OPEN FAILURES, AND THE POINT IS THAT
        // THE REPLAY AGREES WITH IT. Each also appears in the live scoreboard in
        // `docs/browsing-trips.md`; what this file adds is that they are now
        // ARITHMETIC — the same read, offline, forever, so the day one of them
        // changes it changed because the router did. A NEW one is a regression;
        // a FIXED one must be struck off with the round that fixed it, or a
        // round gets credit for a page that simply looked different that day.
        let found = Set(wrong)
        let regressions = found.subtracting(Self.openFailures).sorted()
        let fixed = Self.openFailures.subtracting(found).sorted()
        let newly = "\(regressions.count) NEW recorded-page failure(s):\n"
            + regressions.map { "\($0) — \(detail[String($0.split(separator: " ")[0])] ?? "")" }
                .joined(separator: "\n")
        #expect(regressions.isEmpty, "\(newly)")
        let gone = "\(fixed.count) no longer reproduce — strike them from "
            + "openFailures and say which round did it:\n"
            + fixed.joined(separator: "\n")
        #expect(fixed.isEmpty, "\(gone)")
    }

    /// WHAT ROUND 4 LEFT OPEN, on the pages it recorded.
    ///
    /// R2 — a row satisfying the class IS in the reading and the route missed
    /// it. Two are the same shape: a goal naming something by words the reading
    /// spells differently ("remember me" against a checkbox the page labels
    /// otherwise; a named row on a feed). One is an `openResult` reaching a row
    /// outside any result group, which is the result-group derivation's own gap.
    ///
    /// P — no row in the reading answers the class at all, which is the
    /// detector's recall and belongs in VisionAX rather than here. Both are
    /// result pages whose answer rows the reading did not group.
    static let openFailures: Set<String> = [
        // A goal naming something the reading spells differently. Both reach
        // nothing though rows answering the class are plainly there.
        "check-the-box[0] R2",
        "press-by-name[0] R2",
        // ROUND 5 MOVED THIS ONE FROM P TO R2, which is the whole value of the
        // move: "no row answers the class" blamed the detector's recall, and the
        // truth is that a row does answer and the route reached number 3 of its
        // kind instead of number 1. A routing miss, statable and fixable.
        "site-search[1] R2",
        // STRUCK BY ROUND 6: "search-then-open-second[1] P". It was never
        // perception either. `PageListDerivation` fires correctly on that page —
        // 55 of 107 rows eligible as results, measured live — and the read it was
        // given had 79 rows because the search settled on a FLAT 900ms sleep and
        // read a half-drawn page. The settle polls the tree now and the leg
        // passes four runs out of four. See `WebSearchRecipe.settleForResults`.
        // STRUCK BY ROUND 5: "music-between-two-page-legs[2] R2 reached row 45,
        // which is not inResultGroup". It was never about row 45. The classifier
        // was reading the page the act ARRIVED at rather than the one the route
        // was argued against — see `TripLayer.routedPage` — so a leg that
        // navigated was judged against its own destination. It passes outright.
    ]

    /// THE DRIFT RULE MUST BE ABLE TO FAIL, and until a live round commits its
    /// first recording there is nothing in the repository to prove it with.
    ///
    /// PIN: BUILT FROM A PAGE THAT IS ALREADY HERE. `results-page` is the read
    /// that defeated every ranking, so it is the honest thing to re-argue: a
    /// recording claiming it reached a row is a recording the replay must
    /// contradict, because the live router refuses that page entirely.
    @Test func aRecordingThatDisagreesWithTheRouterIsReportedAsDrift() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PageRoutes/results-page.json")
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        let page = try JSONDecoder().decode(PageRosterFixture.self, from: data)

        let goal = ""
        let query = "fred again video on youtube"
        let live = PageRouter.arbitrate(
            goal: goal, verb: .openResult(query: query), roster: page.roster())
        // The page the router refuses, which is what makes it a fixture.
        #expect(live.winner == nil)

        // A recording claiming otherwise, on the identical read.
        let claimed = RecordedRoute(
            goal: goal, verb: "result", query: query,
            eligibleCount: 0, goalUnmatched: true, selectedOrdinal: 7)
        let again = PageRouter.arbitrate(
            goal: claimed.goal, verb: try #require(Self.verb(claimed)),
            roster: page.roster())
        #expect(
            again.winner?.ordinal != claimed.selectedOrdinal,
            "the drift comparison cannot notice a disagreement")

        // AND IT AGREES WITH ITSELF, so the rule is not simply always unhappy.
        let honest = RecordedRoute(
            goal: goal, verb: "result", query: query,
            eligibleCount: 0, goalUnmatched: true, selectedOrdinal: nil)
        #expect(again.winner?.ordinal == honest.selectedOrdinal)
    }

    // MARK: - The two cases that need a fake, not a recording

    /// A PAGE THAT NEVER SETTLES IS REPORTED AS NOT HAVING ARRIVED.
    ///
    /// PIN: THE `navigation-stalls` TRIP, AND IT CANNOT BE A LIVE ONE. Making a
    /// real browser fail to load on demand is not something a round can stage,
    /// and waiting out the ten-second budget against a real clock would spend
    /// most of a suite proving arithmetic. The fake clock is the trip.
    @Test func aNavigationThatNeverSettlesIsRefused() async {
        // The shell never changes, so nothing ever says the page arrived.
        let shell = FakeShell([BrowsingFixtures.shell(title: "A Page")])
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]))

        let outcome = await engine.navigate(
            .open("https://example.com/"), in: BrowsingFixtures.target())

        #expect(outcome.ok == false)
        #expect(outcome.refusal == .navigationDidNotSettle)
        #expect(outcome.landed == false)
        // AND IT DID TYPE THE ADDRESS — the refusal is about settling, not about
        // having refused to try.
        #expect(shell.opened.count == 1)
    }

    /// SOMEBODY TAKING THE MACHINE MID-PLAN STOPS IT AND SAYS WHERE IT GOT TO.
    ///
    /// PIN: THE `focus-lost-mid-plan` TRIP. A plan that keeps pressing into
    /// whatever came forward is worse than one that stops — it types somebody's
    /// query into a window they were reading. Live, this needs a person to click
    /// away at the right moment; here the stage simply stops holding focus.
    @Test func aPlanInterruptedByAnotherApplicationStopsAndSaysWhere() async {
        let page = BrowsingFixtures.page([
            (role: "AXTextField", label: "Search this site", affordance: .fill),
            (role: "AXButton", label: "Go", affordance: .press),
        ])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [page, page, page]),
            stage: FakeStage(succeeds: true, keepsFocus: false))

        let outcome = await engine.fillOnPage(
            "search this site", text: "alpine touring boots", submit: true,
            in: BrowsingFixtures.target())

        #expect(outcome.landed == false)
        // WHICH STEP IT GOT TO IS THE POINT. "It didn't work" is the answer this
        // whole receipt ladder exists to stop being given.
        let stopped = outcome.receipts.contains { receipt in
            switch receipt.delivery {
            case .interrupted: return true
            case .refused(let refusal):
                if case .interrupted = refusal { return true }
                return false
            default: return false
            }
        }
        let said = outcome.receipts.map(\.spoken).joined(separator: " · ")
        #expect(stopped || outcome.refusal != nil, "\(said)")
    }
}

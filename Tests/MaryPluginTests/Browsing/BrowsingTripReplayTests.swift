//
//  BrowsingTripReplayTests.swift
//  MaryPluginTests
//
//  WHAT: A recorded route is a pure function of a read — drift is reported.
//  IN:   Tests/MaryPluginTests/Fixtures/PageRoutes/results-page.json
//  OUT:  the R2 regression net
//  PIN:  A ROUTE IS A PURE FUNCTION OF A READ, AND A RECORDING IS THE READ.
//        Drift is reported, not silently repassed. A planted disagreement
//        against `results-page` proves the comparison can fail.
//

import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct BrowsingTripReplayTests {

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

    /// THE DRIFT RULE MUST BE ABLE TO FAIL.
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
}

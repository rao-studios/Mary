//
//  PageRouteFixtureTests.swift
//  MaryPluginTests
//
//  WHAT: Real pages, recorded, re-argued — the routing decisions that can only be got
//        wrong against a page nobody could put in a test before.
//  OUT:  PageRouter over PageRosterFixture
//  PIN:  EVERY WRONG PRESS THIS LANE HAS MADE WAS MADE AGAINST A LIVE PAGE. The strip
//        that won on page order, the echo that won on word cover, the region picker that
//        won because it happened to be first — each was found by driving a browser by
//        hand and each was unreproducible the moment the page changed. Captured with
//        `mary-web-probe --save-roster`, they become arithmetic.
//        THE FIXTURE IS FOUND BY PATH, not by SwiftPM resources: the probe writes it and
//        a person reads it, so it lives beside the test as an ordinary file — the same
//        way `NoSiteShortcutsTests` reaches the sources it scans.
//

import Foundation
import Testing
@testable import MaryPlugin

@Suite struct PageRouteFixtureTests {

    /// A RECORDED PAGE THAT IS NOT THERE FAILS THE TEST THAT NEEDED IT. A load
    /// that answered nil let seven tests return early and pass over a fixture
    /// somebody had deleted — and a rule that cannot fail is a comment.
    static func load(_ name: String) throws -> PageRosterFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PageRoutes/\(name).json")
        let data = try #require(
            FileManager.default.contents(atPath: url.path), "no recorded page at \(url.path)")
        return try JSONDecoder().decode(PageRosterFixture.self, from: data)
    }

    /// THE PAGE THAT DEFEATED EVERY RANKING, AND WHY IT IS REFUSED.
    ///
    /// A live search read eighty rows and marked five actionable — a search box, two
    /// sign-in buttons, an icon. What the reading held besides was the site's own
    /// furniture (a region picker, a navigation strip, thirteen related-search
    /// suggestions, the query echoed twice) and the real titles BROKEN ACROSS ROWS:
    /// "again.. - Rooftop Live (Arun's Roof," in one and "pn) - YouTube" in another.
    /// There is no answer in that pool to pick, so the honest reply is that the results
    /// cannot be made out — and every row says which kind of thing it was instead.
    @Test func theRecordedResultsPageIsRefusedRatherThanGuessedAt() throws {
        let fixture = try Self.load("results-page")
        let roster = fixture.roster()
        #expect(roster.elements.count == 80, "the recording is the whole page")

        let routed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "fred again video on youtube"),
            roster: roster)

        #expect(routed.winner == nil, "nothing on this page may be pressed")
        #expect(routed.trace.eligibleCount == 0)
        #expect(routed.trace.decisions.count == roster.elements.count)
        #expect(routed.trace.decisions.allSatisfy { !$0.reason.isEmpty })
    }

    /// AND IT SAYS WHICH KIND OF THING EACH ROW WAS. A refusal nobody can read is a
    /// refusal nobody can fix, and these are the sentences that name the detector's gap.
    @Test func everyRefusedRowIsNamedForWhatItIs() throws {
        let fixture = try Self.load("results-page")
        let routed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "fred again video on youtube"),
            roster: fixture.roster())
        let reasons = Set(routed.trace.decisions.map(\.reason))

        #expect(reasons.contains("is the query echoed back"))
        #expect(reasons.contains("is an address, not a title"))
        #expect(reasons.contains("has no name anyone wrote"))
        #expect(reasons.contains("was named but sits in no result group"))
    }

    /// THE SITE'S OWN RESULTS PAGE, AND THE SAME GAP. A search made on the site itself
    /// read 142 rows: a sponsored card, a knowledge panel, a channel line — and not one
    /// video title. So "the first video" reaches nothing, and it must not answer with the
    /// first of whatever else was there, which is what counting rows at large did.
    @Test func aVideoIsNotPickedFromAPageThatHoldsNone() throws {
        let fixture = try Self.load("video-results")
        let roster = fixture.roster()
        #expect(roster.elements.count > 100, "the recording is the whole page")

        let routed = PageRouter.arbitrate(
            goal: "the first video", verb: .press, roster: roster)

        #expect(routed.winner == nil, "nothing on this page is a video")
        #expect(routed.refusal == .elementNotFound("the first video"))
        // And it was not for want of rows to consider.
        #expect(routed.trace.eligibleCount > 20)
    }

    /// AND THE ROW A PERSON CAN SEE IS REACHED BY ITS OWN WORDS. The reading named the
    /// site's search field "Search or ask a question" and declined to call it fillable;
    /// naming what it says still reaches it, which is what the candidate rung is for.
    @Test func aNamedFieldIsReachedByTheWordsThePageWrote() throws {
        let fixture = try Self.load("video-results")
        let roster = fixture.roster()
        guard roster.elements.contains(where: {
            $0.label.localizedCaseInsensitiveContains("search or ask")
        }) else { return }

        let routed = PageRouter.arbitrate(
            goal: "search or ask", verb: .fill, roster: roster)
        #expect(routed.winner?.label.localizedCaseInsensitiveContains("search or ask") == true)
    }

    /// A REAL TITLE MIS-GROUPED AS "TOOLBAR" IS REACHED BY ITS OWN NAME.
    ///
    /// The site's own search results split this title across two rows and VisionAX
    /// grouped both under "toolbar" — the same kind that means genuine nav chrome
    /// elsewhere on this page, which is exactly why an unconditional toolbar exclusion
    /// used to refuse a real answer a person named precisely. Naming it exactly still
    /// has to reach it; guessing among the page's furniture still must not.
    @Test func aRealTitleMisgroupedAsToolbarIsReachedByName() throws {
        let fixture = try Self.load("site-search-results")
        let roster = fixture.roster()
        #expect(roster.elements.count > 90, "the recording is the whole page")
        guard roster.elements.contains(where: {
            $0.label.contains("ELEVIN Hybrid Set")
        }) else { return }

        let named = PageRouter.arbitrate(
            goal: "ELEVIN Hybrid Set", verb: .openResult(query: "fred again"), roster: roster)
        #expect(named.winner?.label.contains("ELEVIN Hybrid Set") == true)

        // And with nothing named, the no-pick guess still refuses this page's furniture
        // rather than opening whatever a toolbar-grouped row happens to be.
        let guessed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "fred again"), roster: roster)
        #expect(guessed.winner == nil)
    }

    /// THE ADDRESS NEVER REACHES THE REPOSITORY. The lane speaks site names and never
    /// URLs; a recorded page must not be the one place a query string survives.
    @Test func aRecordedPageHoldsNoAddresses() throws {
        for name in ["results-page", "site-search-results"] {
            let fixture = try Self.load(name)
            for row in fixture.rows where row.label.lowercased().hasPrefix("http") {
                // The scheme is kept so the rule that turns an address away can still
                // fire; the host and everything after it is what must not be here.
                #expect(
                    row.label == PageRosterFixture.maskedAddress,
                    "an address survived the recording (\(name)): \(row.label)")
            }
        }
    }

    /// A RECORDING IS THE READ, so what comes back out of it is what went in.
    @Test func aRecordedPageRoundTrips() throws {
        let fixture = try Self.load("results-page")
        let roster = fixture.roster()
        let again = PageRosterFixture(roster: roster).roster()

        #expect(again.elements.map(\.label) == roster.elements.map(\.label))
        #expect(again.map.groups.count == roster.map.groups.count)
        #expect(again.actionable.count == roster.actionable.count)
        #expect(again.rows.map(\.affordanceSource) == roster.rows.map(\.affordanceSource))
    }
}

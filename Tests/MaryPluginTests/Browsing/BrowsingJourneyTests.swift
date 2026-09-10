//
//  BrowsingJourneyTests.swift
//  MaryPluginTests
//
//  WHAT: The three browsing flows that remain without a trip corpus — a
//        watch journey from a blank page, and a minimized window's raise road.
//  OUT:  WatchRecipe, FakeStage raise / noVisibleWindow
//  PIN:  A ROW'S SITE, NOT ITS LABEL. A related-search suggestion that says
//        "youtube" is not a result that goes there; `FakePage.rowPages` keeps
//        the site the AX-shaped shim would drop.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct BrowsingJourneyTests {

    // MARK: - WatchRecipe helpers

    @Test func theShortestNamedRowIsTheSitesFrontDoor() {
        func row(_ ordinal: Int, _ label: String, site: String?) -> PageRow {
            PageRow(
                ordinal: ordinal,
                frame: CGRect(x: 140, y: 240 + CGFloat(ordinal) * 60, width: 500, height: 40),
                label: label, labelSource: .classifier, affordance: .press,
                site: site)
        }
        let door = WatchRecipe.frontDoor(to: "youtube", among: [
            row(1, "An article about youtube's history", site: "youtube"),
            row(2, "YouTube", site: "youtube"),
            row(3, "YouTube", site: "example"),
        ])
        #expect(door?.ordinal == 2)
        #expect(WatchRecipe.frontDoor(to: "youtube", among: [
            row(1, "Somewhere else", site: "example"),
        ]) == nil)
    }

    @Test func theSitesOwnWordsComeOutOfTheQuery() {
        #expect(
            WatchRecipe.withoutSite("youtube", in: "watch a fireplace video on youtube")
                == "watch a fireplace video")
        #expect(WatchRecipe.withoutSite("youtube", in: "youtube") == "youtube")
    }

    // MARK: - Blank page to a named site

    /// SEARCH, THEN OPEN THE ROW THAT GOES TO THE SITE THEY NAMED.
    ///
    /// A suggestion that merely says "youtube" is not a YouTube result. The
    /// page's own `site` is the gate.
    @Test func aWatchJourneyOpensTheNamedSitesResult() async {
        let query = "watch a fireplace video on youtube"
        let home = BrowsingFixtures.shell(title: "Home", url: "https://example.com/")
        let results = BrowsingFixtures.shell(
            title: "fireplace — results",
            url: "https://example.com/?q=watch+a+fireplace+video+on+youtube")
        let watchPage = BrowsingFixtures.shell(
            title: "Cozy Fireplace - YouTube",
            url: "https://example.com/watch")

        func result(_ ordinal: Int, _ label: String, site: String?) -> PageRow {
            PageRow(
                ordinal: ordinal,
                frame: CGRect(x: 140, y: 240 + CGFloat(ordinal) * 60, width: 500, height: 40),
                label: label, labelSource: .classifier, affordance: .press,
                affordanceSource: .classifier, kind: .video,
                group: PageGroupRef(id: 1, kind: .list), confidence: 1,
                facts: [.inResultGroup], provenance: .accessibility, site: site)
        }
        let youtube = result(2, "Cozy Fireplace burning in a stone hearth", site: "youtube")
        let rows = [
            result(1, "How to grow a youtube channel this year", site: nil),
            youtube,
            result(3, "Fireplace Shop — buy a stove", site: "example"),
        ]

        let shell = FakeShell([home, home, results])
        let hands = FakeHands()
        hands.onClick = { shell.readings = [watchPage] }
        let page = FakePage([BrowsingFixtures.media(playing: .playing)])
        page.rowPages = [rows]
        let engine = BrowsingFixtures.engine(shell: shell, page: page, hands: hands)

        _ = await engine.watch(query, in: BrowsingFixtures.target())

        #expect(shell.opened == [query], "the query is typed, not authored as an address")
        #expect(
            hands.clicks.contains { youtube.frame.contains($0) },
            "clicked \(hands.clicks) — wanted the youtube-site row")
        #expect(await engine.snapshot().lastWatchRoad == WatchRecipe.Road.results.rawValue)
    }

    // MARK: - Window minimized

    /// A MINIMIZED WINDOW IS RESTORED ON THE RAISE ROAD, then the act lands.
    @Test func aMinimizedWindowIsRaisedThenTheActLands() async {
        let stage = FakeStage(outcomes: [
            .lost(.noVisibleWindow),
            .won(.raised),
        ])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([
                BrowsingFixtures.media(playing: .playing),
                BrowsingFixtures.media(playing: .paused),
            ]),
            stage: stage)

        let outcome = await engine.controlMedia(.pause, in: BrowsingFixtures.target())

        #expect(outcome.landed, "\(outcome.spoken)")
        #expect(stage.taken.count == 2)
        #expect(stage.raised.count == 1)
    }

    /// NOTHING ON SCREEN STAYS A DISTINCT SENTENCE from a refused activation.
    @Test func noVisibleWindowIsItsOwnRefusal() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage([BrowsingFixtures.media()]),
            stage: FakeStage(outcomes: [.lost(.noVisibleWindow)]))
        let outcome = await engine.controlMedia(.pause, in: BrowsingFixtures.target())
        #expect(outcome.refusal == .activationRefused("A Browser", .noVisibleWindow))
        #expect(outcome.spoken == "A Browser is in front, but none of its windows are on screen.")
        #expect(
            BrowserRefusal.activationRefused("A Browser", .noVisibleWindow).summary
                != BrowserRefusal.activationRefused("A Browser", .refused).summary)
    }
}

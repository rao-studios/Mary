//
//  PageMapProjectionTests.swift
//  MaryPluginTests
//
//  WHAT: What a page read looks like to someone WATCHING — the rows, the offers, the
//        engine's own event lines, and the receipt words behind a summary.
//  OUT:  PageMapProjection, BrowserEngineEvent.line, SkillOutcome.receiptWords
//  PIN:  THIS IS THE HALF OF SAND'S OVERLAY THAT CAN BE PINNED. The app draws; the
//        decisions — which rows, what they are called, what the caption claims — are
//        made here, so this suite is the whole guarantee that the stage is not quietly
//        lying about a page.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import Testing
@testable import MaryPlugin

@Suite struct PageMapProjectionTests {

    /// A stage whose plane is the identity: 1000×1000 of desktop drawn at 1000×1000, so
    /// a converted rect is the frame itself and a wrong conversion is visible as such.
    private let plane = AXDesktopPlane(
        desktopBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
        screenBounds: [CGRect(x: 0, y: 0, width: 1000, height: 1000)])
    private let size = CGSize(width: 1000, height: 1000)

    private func roster(
        _ rows: [(role: String, label: String, affordance: SeenAffordance)],
        group: (kind: String, title: String?)? = nil,
        capturedAt: Date = Date()
    ) -> PageRoster {
        let page = BrowsingFixtures.page(rows, group: group)
        return PageRoster(
            elements: page.elements, map: page.map,
            pageFrame: BrowsingFixtures.pageFrame, capturedAt: capturedAt)
    }

    // MARK: - The route, as somebody reads it

    /// SELECTED FIRST, THEN THE RIVALS, THEN EVERYTHING TURNED DOWN. The pane answers
    /// "why that row and not another", so the row it chose must not be somewhere down a
    /// list of eighty.
    @Test func routeLinesPutTheChosenRowFirst() {
        let page = roster([
            (role: "AXLink", label: "Terms of service", affordance: .press),
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
        ])
        let routed = PageRouter.arbitrate(
            goal: "alpine touring boots reviewed", verb: .press, roster: page)
        let lines = PageMapProjection.routeLines(for: routed.trace)

        #expect(lines.count == 2)
        #expect(lines.first?.id == 2)
        #expect(lines.first?.disposition == .selected)
        #expect(lines.first?.text.contains("Alpine touring boots reviewed") == true)
        // The sentence is the half a person learns the rules from.
        #expect(lines.allSatisfy { !$0.reason.isEmpty })
    }

    /// A ROW CARRIES WHAT THE ROUTE MADE OF IT, so the stage can draw the chosen one
    /// heavier and its rivals dashed without deciding anything itself.
    @Test func drawnRowsCarryTheRouteDisposition() {
        let page = roster([
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXLink", label: "Terms of service", affordance: .press),
        ])
        let routed = PageRouter.arbitrate(
            goal: "alpine touring boots reviewed", verb: .press, roster: page)
        let rows = PageMapProjection.rows(
            for: page, plane: plane, size: size, route: routed.trace)

        #expect(rows.first(where: { $0.id == 1 })?.routeDisposition == .selected)
        #expect(rows.first(where: { $0.id == 2 })?.routeDisposition != .selected)
    }

    /// AND WITH NO ROUTE THE STAGE DRAWS THE PAGE AND CLAIMS NOTHING.
    @Test func withNoRouteNoRowClaimsADisposition() {
        let rows = PageMapProjection.rows(
            for: roster([(role: "AXLink", label: "Anything at all", affordance: .press)]),
            plane: plane, size: size)
        #expect(rows.allSatisfy { $0.routeDisposition == nil })
    }

    /// THE GAP THE PANEL EXISTS TO SHOW: what the map offered, beside what it merely
    /// named. A results page offering four icons while sixty rows carry real names is the
    /// whole diagnosis, and both numbers come from the same read.
    @Test func offersAndCandidatesAreCountedApart() {
        let page = roster([
            (role: "AXTextField", label: "Search this site", affordance: .fill),
            (role: "AXLink", label: "Alpine touring boots reviewed",
             affordance: SeenAffordance.none),
            (role: "AXLink", label: "How to choose touring boots",
             affordance: SeenAffordance.none),
        ])
        let offers = PageMapProjection.offerLines(for: page)
        let candidates = PageMapProjection.candidateLines(for: page)

        #expect(offers.map(\.text) == ["1 · field · Search this site"])
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.text.contains("link") })
    }

    @Test func everyRowIsDrawnWhereTheReadingSawIt() {
        let rows = PageMapProjection.rows(
            for: roster([
                (role: "AXLink", label: "Alpine touring boots", affordance: .press),
                (role: "AXTextField", label: "Search", affordance: .fill),
            ], group: (kind: "row", title: "Results")),
            plane: plane, size: size)

        #expect(rows.count == 2)
        #expect(rows.map(\.id) == [1, 2])
        #expect(rows.first?.rect == CGRect(x: 140, y: 240, width: 400, height: 40))
        #expect(rows.first?.affordance == .press)
        #expect(rows.last?.affordance == .fill)
        #expect(rows.first?.caption == "Results")
    }

    /// A ROW THAT CANNOT BE ACTED ON IS STILL DRAWN. A page that reads as all-`.none` is
    /// the failure the overlay exists to show, and drawing nothing would look identical
    /// to a page with nothing on it.
    @Test func rowsThatOfferNothingAreDrawnAnyway() {
        let rows = PageMapProjection.rows(
            for: roster([(role: "AXStaticText", label: "Terms", affordance: SeenAffordance.none)]),
            plane: plane, size: size)

        #expect(rows.count == 1)
        #expect(rows.first?.affordance == SeenAffordance.none)
    }

    /// A SYNTHESIZED NAME IS NOT A NAME, and the stage says so rather than drawing the
    /// reading's own invention as though the page had written it.
    @Test func anInventedNameIsMarkedAsOne() {
        var roster = roster([(role: "AXButton", label: "button 3", affordance: .press)])
        roster.map.annotations[1] = SeenElementAnnotation(
            affordance: .press, labelSource: .synthesized)

        let rows = PageMapProjection.rows(for: roster, plane: plane, size: size)

        #expect(rows.first?.isNamed == false)
        #expect(rows.first?.label == PageMapProjection.unnamed)
    }

    /// A row the plane cannot give area to is not drawn — a zero-sized stroke is a dot
    /// in the corner of the stage, which reads as a control that is not there.
    @Test func aRowWithNoAreaIsNotDrawn() {
        var roster = roster([(role: "AXLink", label: "Alpine", affordance: .press)])
        roster.elements[0].frame = CGRect(x: 10, y: 10, width: 0, height: 0)

        #expect(PageMapProjection.rows(for: roster, plane: plane, size: size).isEmpty)
    }

    // MARK: - What a phrase can reach

    /// THE GAP BETWEEN ROWS AND OFFERS IS THE WHOLE DIAGNOSIS. A page can draw ten
    /// things and offer three; the overlay shows both so the missing seven are visible
    /// as rows that no phrase could ever have named.
    @Test func onlyNamedActionableRowsBecomeOffers() {
        var roster = roster([
            (role: "AXLink", label: "Alpine touring boots", affordance: .press),
            (role: "AXStaticText", label: "Terms", affordance: SeenAffordance.none),
            (role: "AXButton", label: "button 3", affordance: .press),
        ])
        // The third row's name was invented from its position.
        roster.map.annotations[3] = SeenElementAnnotation(
            affordance: .press, labelSource: .synthesized)

        let offers = PageMapProjection.offerLines(for: roster)

        #expect(offers.count == 1)
        #expect(offers.first?.text.contains("Alpine touring boots") == true)
        #expect(offers.first?.isEnabled == true)
        // Three rows drawn, one reachable — the point of showing both.
        #expect(PageMapProjection.rows(for: roster, plane: plane, size: size).count == 3)
    }

    /// THE CAPTION'S AGE IS THE HALF THAT MATTERS: without it nobody can tell a live
    /// page from one that closed a minute ago.
    @Test func theCaptionSaysWhatWasReadAndWhen() {
        let now = Date()
        let fresh = roster([
            (role: "AXLink", label: "Alpine", affordance: .press),
            (role: "AXLink", label: "Boots", affordance: .press),
        ], capturedAt: now.addingTimeInterval(-4))

        let caption = PageMapProjection.caption(for: fresh, at: now)
        #expect(caption == "2 rows · 2 named · 4s ago")
        #expect(!caption.contains("STALE"))
    }

    @Test func aReadPastTheHorizonSaysSo() {
        let now = Date()
        let old = roster(
            [(role: "AXLink", label: "Alpine", affordance: .press)],
            capturedAt: now.addingTimeInterval(-(PageMapProjection.horizon + 1)))

        #expect(PageMapProjection.caption(for: old, at: now).contains("STALE"))
    }

}

/// The words a watcher is given for something that already happened.
@Suite struct BrowsingWatcherWordsTests {

    // MARK: - What a watcher is told

    /// ONE VOCABULARY: the probe timing a roundtrip and the bench drawing a timeline
    /// read the same stream, and a line that differed between them could not be
    /// compared across them.
    @Test func everyBrowsingEventSaysWhatItWas() {
        let lines: [String] = [
            .init(BrowserEngineEvent.resolved(browser: "Chrome", pid: 1).line),
            .init(BrowserEngineEvent.shellRead(
                title: "Results", site: "example", pageFrame: nil).line),
            .init(BrowserEngineEvent.read(rows: 12, named: 9, groups: 2).line),
            .init(BrowserEngineEvent.matched(phrase: "the first one", to: "Alpine").line),
            .init(BrowserEngineEvent.verified("it played").line),
            .init(BrowserEngineEvent.refused(.elementNotFound("the blue one")).line),
        ]
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(lines[0] == "resolved Chrome")
        #expect(lines[1].contains("Results") && lines[1].contains("example"))
        #expect(lines[2] == "looked — 12 rows, 9 named, 2 groups")
        #expect(lines[3].contains("the first one") && lines[3].contains("Alpine"))
        #expect(lines[5].hasPrefix("refused — "))
        // AND NO ADDRESS EVER, on any of them.
        #expect(!lines.contains { $0.contains("http") })
    }

    /// Only the refusal is a refusal — the timeline colours on this and nothing else.
    @Test func onlyARefusalReadsAsOne() {
        #expect(BrowserEngineEvent.refused(.pageNotVisible).isRefusal)
        #expect(!BrowserEngineEvent.acted("pressed play").isRefusal)
        #expect(!BrowserEngineEvent.verified("it played").isRefusal)
    }

    // MARK: - Receipts

    /// THE FOUR FACTS THAT SAY WHETHER THE SUMMARY IS TRUE.
    @Test func anOutcomeSaysWhatActuallyHappened() {
        let outcome = SkillOutcome(
            ok: true, summary: "Pressed play.",
            landed: true,
            adapterTrail: [AdapterID("web-surface"), AdapterID("chrome")],
            applicationID: "com.google.Chrome")

        let words = outcome.receiptWords
        #expect(words.contains("landed"))
        #expect(words.contains("com.google.Chrome"))
        #expect(words.contains("web-surface → chrome"))
        #expect(!words.contains("found nothing"))
    }

    /// AND A PLAIN OUTCOME PRINTS NO ORNAMENT.
    @Test func anOrdinaryOutcomeHasNoReceiptWords() {
        #expect(SkillOutcome(ok: true, summary: "Done.").receiptWords.isEmpty)
    }
}

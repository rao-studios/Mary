//
//  BrowsingLatencyTests.swift
//  MaryPluginTests
//
//  WHAT: The act stops at its next safe point when the stage is asked for, the
//        receipt read's slate is deferred past the act, and every step says
//        what it cost.
//  OUT:  BrowserStaging.preemptRequested, BrowserEngine.deferSlate, .timed
//  PIN:  ONE CLICK TOOK 8.7 SECONDS and nothing on the path could say where.
//        These pin the two structural cuts (a preempt the browser honours; the
//        receipt read that no longer embeds every row inside the act) and the
//        timing lines that make the next reconstruction a measurement.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct BrowsingLatencyTests {

    static func page(_ labels: [String]) -> (elements: [AXScreenElement], map: PageMapSummary) {
        BrowsingFixtures.page(labels.map { (role: "AXLink", label: $0, affordance: .press) })
    }

    /// ANOTHER ACT ASKED FOR THE STAGE — the press does not happen.
    @Test func aPreemptedPressStopsBeforeClicking() async {
        let hands = FakeHands()
        let stage = FakeStage()
        stage.preempt = true
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [Self.page(["Alpine touring boots reviewed"])]),
            hands: hands, stage: stage)

        let outcome = await engine.pressOnPage("Alpine touring boots reviewed", in: BrowsingFixtures.target())

        #expect(hands.clicks.isEmpty)
        #expect(outcome.refusal == .interrupted(atCommand: 0), "\(outcome.spoken)")
    }

    /// AND A SETTLE STOPS WAITING, rather than spending the whole budget.
    @Test func aPreemptedSettleStopsWaiting() async {
        let shell = FakeShell([BrowsingFixtures.shell(title: "A Page")])
        let stage = FakeStage()
        stage.preempt = true
        let engine = BrowsingFixtures.engine(shell: shell, page: FakePage([nil]), stage: stage)

        let outcome = await engine.navigate(.open("https://example.com/"), in: BrowsingFixtures.target())

        #expect(outcome.refusal == .interrupted(atCommand: 0), "\(outcome.spoken)")
        #expect(shell.preferred.count <= 2, "stopped at the first poll, read \(shell.preferred.count) times")
    }

    /// THE RECEIPT READ IS THE ENGINE'S ROSTER AT ONCE — deferring the slate
    /// does not defer the evidence.
    @Test func theReceiptReadIsTheEnginesRosterAtOnce() async {
        let before = Self.page(["Alpine touring boots reviewed", "The ten best"])
        let after = Self.page(["Alpine touring boots reviewed", "Something else", "A third"])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [before, after]))

        _ = await engine.pressOnPage("Alpine touring boots reviewed", in: BrowsingFixtures.target())

        #expect(await engine.snapshot().lastRoster?.elements.count == 3)
    }

    /// EVERY STEP SAYS WHAT IT COST. The stage, the shell read and the page read
    /// each put a timed line on the stream — the numbers a reconstruction of
    /// a slow act had to guess.
    @Test func theStageTheShellAndThePageReadAreTimed() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [Self.page(["Alpine touring boots reviewed"])]))

        _ = await engine.pressOnPage("Alpine touring boots reviewed", in: BrowsingFixtures.target())

        let recent = await engine.snapshot().recent
        #expect(recent.contains { $0.hasPrefix("the stage ") }, "\(recent)")
        #expect(recent.contains { $0.hasPrefix("shell read ") }, "\(recent)")
        #expect(recent.contains { $0.hasPrefix("page read ") }, "\(recent)")
    }
}

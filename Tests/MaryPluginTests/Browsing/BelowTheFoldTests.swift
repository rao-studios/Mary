//
//  BelowTheFoldTests.swift
//  MaryPluginTests
//
//  WHAT: A named thing the page is not showing yet.
//  PIN:  THE TREE ENDS AT THE FOLD, AND IT IS NOT A BUDGET. Measured live on a
//        whole encyclopedia article, walked eighty deep and sixty thousand nodes
//        wide: eight hundred and eleven accessibility nodes exist for the entire
//        document, none of them off screen, and everything below the fold is
//        published as a ONE-PIXEL sliver at the viewport's edge carrying no name.
//        So there is no larger read to take. The only way to a row six screens
//        down is to move the page — which makes navigation, scrolling and
//        "what is on this page" one problem rather than three, and this file is
//        where that is kept true.
//        ONLY A NAME SEARCHES. "The third link" means the third of the ones the
//        person can SEE. Scrolling to count things they never saw answers a
//        question nobody asked, and the ordinal case below is what stops it.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct BelowTheFoldTests {

    /// A page whose first read does not hold the target and whose later reads do
    /// — which is what scrolling a real page does to a real read.
    static func engineFindingItAfter(
        _ screens: Int, hands: FakeHands
    ) -> BrowserEngine {
        let without = BrowsingFixtures.page([
            (role: "AXLink", label: "Home", affordance: .press),
            (role: "AXLink", label: "About", affordance: .press),
        ])
        let with = BrowsingFixtures.page([
            (role: "AXLink", label: "Home", affordance: .press),
            (role: "AXLink", label: "About", affordance: .press),
            (role: "AXLink", label: "Ski mountaineering", affordance: .press),
        ])
        // One read per attempt before it appears, then it stays.
        var pages = Array(repeating: without, count: screens + 1)
        pages.append(with)
        pages.append(with)
        pages.append(with)
        return BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: pages),
            hands: hands)
    }

    /// A NAME NOT ON SCREEN IS LOOKED FOR, AND THEN PRESSED.
    @Test func aNamedRowBelowTheFoldIsFoundByScrollingAndPressed() async {
        let hands = FakeHands()
        let engine = Self.engineFindingItAfter(2, hands: hands)

        let outcome = await engine.pressOnPage(
            "Ski mountaineering", in: BrowsingFixtures.target())

        // IT SCROLLED, AND IT SCROLLED DOWN.
        #expect(hands.scrolls.contains { $0 < 0 }, "\(hands.scrolls)")
        // AND IT PRESSED SOMETHING, which the first read had nothing to press.
        #expect(!hands.clicks.isEmpty, "\(outcome.spoken)")
    }

    /// A POSITION DOES NOT SEARCH. See the file header.
    @Test func anOrdinalCountsWhatIsOnScreenAndNeverScrolls() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [BrowsingFixtures.page([
                (role: "AXLink", label: "Home", affordance: .press),
            ])]),
            hands: hands)

        _ = await engine.pressOnPage("the fourth link", in: BrowsingFixtures.target())

        #expect(hands.scrolls.isEmpty, "\(hands.scrolls)")
    }

    /// A GUESS ON THIS SCREEN LOSES TO A NAME ON THE NEXT — and containment is
    /// not a guess.
    ///
    /// PIN: THE RULE STATED DIRECTLY, because the trigger it turns on cannot be
    /// built out of fakes: reaching a row on MEANING ALONE needs a live element
    /// index, and a fake page has none. What can be pinned here is the
    /// judgement itself — which is where the distinction lives that a first
    /// version of this test got wrong. "Equipment" answering "Randonnee racing
    /// equipment" looks like the same sort of guess as "Ski touring" answering
    /// "Ski mountaineering" and is not: the row's own name sits inside what the
    /// person said. Searching on that too would spend four page reads on most
    /// acts to improve a few.
    @Test func onlyAMatchWithNoNamingBehindItIsWorthLookingPast() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [BrowsingFixtures.page([])]))
        let landed = BrowserOutcome(ok: true, spoken: "pressed something")

        func judged(_ basis: PageRouteLexicalBasis, _ outcome: BrowserOutcome) async -> Bool {
            await engine.judgeReachForTests(trace: Self.trace(basis: basis), outcome: outcome)
        }
        #expect(await judged(.none, landed), "meaning alone should look further")
        #expect(await !judged(.contained, landed), "containment is naming evidence")
        #expect(await !judged(.exact, landed))
        // AND A REFUSAL ALWAYS LOOKS, whatever the trace says.
        #expect(await judged(
            .exact, BrowserOutcome(ok: false, spoken: "", refusal: .elementNotFound("x"))))
    }

    /// One selected row, reached on the basis given.
    static func trace(basis: PageRouteLexicalBasis) -> PageRouteTrace {
        PageRouteTrace(
            goal: "a goal", verb: "press",
            decisions: [
                .init(
                    id: 1, label: "a row", kind: "link", disposition: .selected,
                    evidence: PageRouteEvidence(lexical: 0, lexicalBasis: basis),
                    reason: "")
            ])
    }

    /// AND WHEN IT IS NOT THERE, THE PAGE GOES BACK.
    ///
    /// PIN: LEAVING SOMEBODY SIX SCREENS DOWN HAVING FOUND NOTHING is worse than
    /// the refusal they were owed — they now have to find their own place again
    /// to read the answer. Every scroll down is matched by one back up.
    @Test func aSearchThatFindsNothingPutsThePageBack() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [BrowsingFixtures.page([
                (role: "AXLink", label: "Home", affordance: .press),
            ])]),
            hands: hands)

        let outcome = await engine.pressOnPage(
            "a thing this page has not got", in: BrowsingFixtures.target())

        let down = hands.scrolls.filter { $0 < 0 }.count
        let up = hands.scrolls.filter { $0 > 0 }.count
        #expect(down > 0, "it never looked")
        #expect(down == up, "went down \(down), came back \(up)")
        // AND THE REFUSAL IS THE FIRST ONE, not a second one about scrolling.
        #expect(outcome.refusal != nil)
    }
}

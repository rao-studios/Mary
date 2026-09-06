//
//  PageChallengeTests.swift
//  MaryPluginTests
//
//  WHAT: A human-check is recognised from the title alone, pressed once, and
//        handed back honestly when one press does not clear it.
//  OUT:  PageChallenge, BrowserEngine.satisfyingChallenge
//  PIN:  THE SAFETY PROPERTY IS THE FIRST TEST. `satisfyingChallenge` must be a
//        no-op on an ordinary page — it reads the title the shell already has,
//        and touches nothing unless that title is literally an interstitial's.
//        A version that pressed on any page would be pressing a checkbox nobody
//        asked about, which is the opposite of the honest thing this is.
//        AND THE HANDBACK IS THE SECOND. One press, look again, then refuse —
//        never a loop. Hammering a challenge is the behaviour this is not.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryComputerUse
@testable import MaryPlugin

@Suite struct PageChallengeTests {

    // MARK: - Detection

    /// THE INTERSTITIAL OWNS THE TITLE, so the match is a prefix of the folded
    /// title and the trailing site name is noise.
    @Test func aChallengeIsRecognisedFromItsTitle() {
        #expect(PageChallenge.isChallenge(title: "Just a moment..."))
        #expect(PageChallenge.isChallenge(title: "Just a moment… - example"))
        #expect(PageChallenge.isChallenge(title: "Attention Required! | Cloudflare"))
        #expect(PageChallenge.isChallenge(title: "Checking your browser before accessing"))
        #expect(PageChallenge.isChallenge(title: "Verifying you are human. This may take a few seconds."))
    }

    /// AN ORDINARY PAGE IS NOT A CHALLENGE, including one that merely mentions
    /// waiting somewhere in a long title.
    @Test func anOrdinaryTitleIsNotAChallenge() {
        #expect(!PageChallenge.isChallenge(title: "Ski touring - Wikipedia"))
        #expect(!PageChallenge.isChallenge(title: "alpine touring boots - Ecosia"))
        #expect(!PageChallenge.isChallenge(title: "How to please wait staff at a restaurant"))
        #expect(!PageChallenge.isChallenge(title: nil))
        #expect(!PageChallenge.isChallenge(title: ""))
    }

    /// THE CONTROL IS NAMED BY WHAT IT SAYS, and the variants are all one control.
    @Test func theControlIsRecognisedByItsWords() {
        #expect(PageChallenge.namesControl("Verify you are human"))
        #expect(PageChallenge.namesControl("verify you are human "))
        #expect(PageChallenge.namesControl("I'm not a robot"))
        #expect(!PageChallenge.namesControl("Sign in"))
        #expect(!PageChallenge.namesControl("Accept all"))
    }

    // MARK: - The engine flow, against fakes

    /// A NO-OP ON AN ORDINARY PAGE. The outcome is returned untouched and the
    /// hands never move — the property that keeps this from pressing a checkbox
    /// nobody asked about.
    @Test func anOrdinaryNavigationIsNotTouched() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "Ski touring - Wikipedia")]),
            page: FakePage([nil]),
            hands: hands)
        let settled = BrowserOutcome(
            ok: true, spoken: "Opened.",
            shell: BrowsingFixtures.shell(title: "Ski touring - Wikipedia"))

        let out = await engine.satisfyingChallenge(settled, in: BrowsingFixtures.target())

        #expect(out.ok)
        #expect(out.refusal == nil)
        #expect(hands.clicks.isEmpty, "an ordinary page was pressed")
    }

    /// ONE PRESS, THEN AN HONEST HANDBACK. A challenge that never clears is
    /// pressed once — the click is recorded — and then refused, not looped.
    @Test func aChallengeThatDoesNotClearIsHandedBack() async {
        let hands = FakeHands()
        // The interstitial's title stands through every read.
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "Just a moment…")]),
            page: FakePage(pages: [BrowsingFixtures.page([
                (role: "AXCheckBox", label: "Verify you are human", affordance: .press),
            ])]),
            hands: hands)
        let settled = BrowserOutcome(
            ok: true, spoken: "Opened.",
            shell: BrowsingFixtures.shell(title: "Just a moment…"))

        let out = await engine.satisfyingChallenge(settled, in: BrowsingFixtures.target())

        #expect(out.refusal == .humanCheck)
        #expect(!hands.clicks.isEmpty, "the visible control was never pressed")
    }

    /// AND THE CLEAR IS READ THE SAME WAY THE NAVIGATION IS — the title stops
    /// being the interstitial's, and that reading is the receipt.
    @Test func aClearedChallengeIsRecognised() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([
                BrowsingFixtures.shell(title: "Just a moment…"),
                BrowsingFixtures.shell(title: "Ski touring - Wikipedia"),
            ]),
            page: FakePage([nil]))

        let cleared = await engine.challengeCleared(in: BrowsingFixtures.target())
        #expect(cleared?.title == "Ski touring - Wikipedia")
    }

    /// A CHALLENGE THAT NEVER CLEARS RETURNS NIL, within the budget rather than
    /// forever.
    @Test func aPersistentChallengeNeverClears() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell(title: "Just a moment…")]),
            page: FakePage([nil]))
        let cleared = await engine.challengeCleared(
            in: BrowsingFixtures.target(), within: 4)
        #expect(cleared == nil)
    }
}

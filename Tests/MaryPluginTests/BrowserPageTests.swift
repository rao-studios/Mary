//
//  BrowserPageTests.swift
//  MaryPluginTests
//
//  WHAT: The page verbs — reading, resolving, acting, and proving it.
//  OUT:  BrowserEngine+Page, PageActor, PageListing, PageReceipts, WebSearchRecipe
//  PIN:  EVERY REFUSAL AND EVERY RECEIPT RANK IS REACHABLE HERE. The whole argument for
//        this lane is that it says which of a dozen things went wrong, and none of that
//        is provable by driving a real browser by hand.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import MaryFoundation
import Testing
@testable import MaryPlugin

@Suite struct BrowserPageTests {

    private func results() -> (elements: [AXScreenElement], map: PageMapSummary) {
        BrowsingFixtures.page([
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXLink", label: "The best touring boots this year", affordance: .press),
            (role: "AXLink", label: "How to choose touring boots", affordance: .press),
            (role: "AXTextField", label: "Search", affordance: .fill),
        ], group: (kind: "row", title: "Results"))
    }

    // MARK: - Reading

    /// THE LISTING IS WHAT THE MODEL PLANS FROM, so it numbers rows within their kind —
    /// the same way the resolver counts them.
    @Test func readingAPageListsWhatCanBeActedOn() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]))
        let outcome = await engine.readPage(in: BrowsingFixtures.target())

        #expect(outcome.ok)
        #expect(outcome.elements.count == 4)
        #expect(outcome.spoken.contains("link 1 — Alpine touring boots reviewed"))
        #expect(outcome.spoken.contains("link 3 — How to choose touring boots"))
        #expect(outcome.spoken.contains("field 1 — Search"))
        // A read changes nothing, so it never claims to have landed anything.
        #expect(!outcome.landed)
    }

    /// A QUERY NARROWS THE LISTING, and a query that matches nothing still shows the
    /// page rather than claiming it is empty.
    @Test func aQueryNarrowsButNeverEmpties() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]))
        let target = BrowsingFixtures.target()
        let narrowed = await engine.readPage(in: target, query: "best")
        #expect(narrowed.spoken.contains("The best touring boots"))
        #expect(!narrowed.spoken.contains("How to choose"))

        let missed = await engine.readPage(in: target, query: "helicopter")
        #expect(missed.spoken.contains("Alpine touring boots"))
    }

    // MARK: - The roster the engine kept

    /// THE ROSTER IS KEPT AS EVIDENCE, alongside the slate it was published from —
    /// what a debugger draws to show the page the engine actually saw.
    @Test func aReadRemembersTheRosterItPublished() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]))
        #expect(await engine.snapshot().lastRoster == nil, "nothing read, nothing drawn")

        _ = await engine.readPage(in: BrowsingFixtures.target())

        let roster = await engine.snapshot().lastRoster
        #expect(roster?.elements.count == 4)
        #expect(roster?.map.groups.first?.title == "Results")
    }

    /// AND A READ THAT FAILS LEAVES NONE. The retract runs before the look, so a page
    /// that could not be read cannot leave the previous one standing — which is the
    /// whole reason the roster is written where the slate is.
    @Test func aFailedReadLeavesNoRoster() async {
        let page = FakePage(pages: [results()])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]), page: page)
        _ = await engine.readPage(in: BrowsingFixtures.target())
        #expect(await engine.snapshot().lastRoster != nil)

        page.failure = .visionUnavailable("no engine")
        _ = await engine.readPage(in: BrowsingFixtures.target())

        #expect(await engine.snapshot().lastRoster == nil)
    }

    /// A NAVIGATION REPLACES IT WITH WHERE THE BROWSER ARRIVED, never leaving the page
    /// that has gone.
    @Test func aNavigationReplacesTheRoster() async {
        let arrived = BrowsingFixtures.page([
            (role: "AXLink", label: "Buy these boots", affordance: .press),
        ])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([
                BrowsingFixtures.shell(title: "Results"),
                BrowsingFixtures.shell(title: "Boots", url: "https://example.com/a"),
            ]),
            page: FakePage(pages: [results(), arrived]))

        _ = await engine.pressOnPage(
            "Alpine touring boots reviewed", in: BrowsingFixtures.target())

        let roster = await engine.snapshot().lastRoster
        #expect(roster?.elements.map(\.label) == ["Buy these boots"])
    }

    // MARK: - Resolving

    /// THE WORDS FIND THE THING, and the ordinal counts the pool the listing showed.
    @Test func aPhraseAndAnOrdinalBothResolve() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), hands: hands)
        let outcome = await engine.pressOnPage(
            "how to choose", in: BrowsingFixtures.target())
        #expect(outcome.receipts.count == 1)
        #expect(hands.clicks.count == 1)
        // The third row, whose frame the fixture put 120 points below the first.
        #expect(hands.clicks.first?.y == 380)
        _ = outcome
    }

    /// A PHRASE THAT FITS TWO THINGS IS A QUESTION, and the refusal names them.
    @Test func ambiguityNamesTheRivalsAndPressesNothing() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), hands: hands)
        let outcome = await engine.pressOnPage(
            "touring boots", in: BrowsingFixtures.target())

        #expect(!outcome.ok)
        #expect(hands.clicks.isEmpty)
        #expect(outcome.spoken.contains("more than one"))
        #expect(outcome.spoken.contains("Alpine touring boots reviewed"))
    }

    /// A MISS SAYS WHAT WAS LOOKED FOR.
    @Test func aMissIsNamedAndNothingIsPressed() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), hands: hands)
        let outcome = await engine.pressOnPage("the checkout button", in: BrowsingFixtures.target())
        #expect(!outcome.ok)
        #expect(hands.clicks.isEmpty)
        #expect(outcome.spoken.contains("checkout"))
    }

    /// A FIELD IS NOT A BUTTON. Typing into a link is a different mistake from not
    /// finding it, and it is named differently.
    @Test func typingNeedsSomethingTypeable() async {
        let keys = FakeKeys()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), keys: keys)
        let outcome = await engine.fillOnPage(
            "Alpine touring boots reviewed", text: "hello", submit: false,
            in: BrowsingFixtures.target())
        #expect(!outcome.ok)
        #expect(keys.typed.isEmpty)
        #expect(outcome.spoken.contains("isn't something I can type into"))
    }

    // MARK: - Receipts

    /// THE STRONGEST RECEIPT IS THAT THE BROWSER WENT SOMEWHERE.
    @Test func aPressThatNavigatesHasLanded() async {
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([
                BrowsingFixtures.shell(title: "Results"),
                BrowsingFixtures.shell(title: "Alpine touring boots", url: "https://example.com/a"),
            ]),
            page: FakePage(pages: [results()]))
        let outcome = await engine.pressOnPage(
            "Alpine touring boots reviewed", in: BrowsingFixtures.target())

        #expect(outcome.ok)
        #expect(outcome.landed)
        #expect(outcome.receipts.first?.spoken.contains("the page became") == true)
    }

    /// A PRESS THAT CHANGES NOTHING IS DELIVERED AND UNPROVEN — not a success.
    @Test func aPressWithNoEffectDoesNotLand() async {
        let shell = BrowsingFixtures.shell()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([shell, shell, shell]),
            page: FakePage(pages: [results(), results()]))
        let outcome = await engine.pressOnPage(
            "Alpine touring boots reviewed", in: BrowsingFixtures.target())

        #expect(outcome.ok)
        #expect(!outcome.landed)
        #expect(outcome.receipts.first?.spoken.contains("no sign") == true)
    }

    /// THE PAGE MERELY DIFFERING IS A SIGN, NOT PROOF. Adverts rotate on their own.
    @Test func aRosterDifferenceIsWeakEvidence() async {
        let shell = BrowsingFixtures.shell()
        let after = BrowsingFixtures.page([
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXLink", label: "Something else entirely", affordance: .press),
            (role: "AXLink", label: "A third new thing", affordance: .press),
        ])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([shell, shell, shell]),
            page: FakePage(pages: [results(), after]))
        let outcome = await engine.pressOnPage(
            "Alpine touring boots reviewed", in: BrowsingFixtures.target())
        #expect(outcome.ok)
        #expect(!outcome.landed)
        #expect(outcome.receipts.first?.spoken.contains("the page changed") == true)
    }

    /// TYPED TEXT IN THE FIELD IS PROOF.
    @Test func typedTextInTheFieldIsProof() async {
        let shell = BrowsingFixtures.shell()
        let after = BrowsingFixtures.page([
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXLink", label: "The best touring boots this year", affordance: .press),
            (role: "AXLink", label: "How to choose touring boots", affordance: .press),
            (role: "AXTextField", label: "Search", affordance: .fill),
        ])
        // The typed words appear where the field is.
        var withText = after
        withText.elements.append(AXScreenElement(
            ordinal: 5, id: AXNodeID(raw: 9), pid: 1234, appName: "A Browser",
            windowID: AXNodeID(raw: 1), windowTitle: "A Page", role: "AXStaticText",
            category: .text, label: "lofi beats radio",
            frame: after.elements[3].frame, provenance: .seen))
        let keys = FakeKeys()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([shell, shell, shell]),
            page: FakePage(pages: [results(), withText]), keys: keys)
        let outcome = await engine.fillOnPage(
            "Search", text: "lofi beats radio", submit: false, in: BrowsingFixtures.target())

        #expect(keys.typed == ["lofi beats radio"])
        #expect(outcome.landed)
    }

    /// SUBMIT PRESSES RETURN, and nothing else ever does.
    @Test func submitPressesReturn() async {
        let keys = FakeKeys()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), keys: keys)
        _ = await engine.fillOnPage(
            "Search", text: "boots", submit: true, in: BrowsingFixtures.target())
        #expect(keys.pressed == [.return])
    }

    /// LOSING THE FIELD MID-WORD MUST NOT COMMIT HALF A PHRASE.
    @Test func typingThatLosesFocusRefuses() async {
        let keys = FakeKeys()
        keys.typeSucceeds = false
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), keys: keys)
        let outcome = await engine.fillOnPage(
            "Search", text: "boots", submit: true, in: BrowsingFixtures.target())
        #expect(!outcome.ok)
        #expect(keys.pressed.isEmpty)
    }

    // MARK: - Plans

    /// A PLAN RUNS IN ORDER AND RE-READS BEFORE EVERY STEP.
    @Test func aPlanRunsEveryStepAndReadsBetweenThem() async {
        let hands = FakeHands()
        let keys = FakeKeys()
        let page = FakePage(pages: [results()])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]), page: page,
            hands: hands, keys: keys)
        let plan = PageInteractionPlan.of([
            .typeText(.init(target: "Search", text: "boots", submit: true)),
            .click(.init(location: .target("How to choose touring boots"))),
        ])
        let outcome = await engine.act(plan, in: BrowsingFixtures.target())

        #expect(outcome.receipts.map(\.kind) == [.typeText, .click])
        #expect(keys.typed == ["boots"])
        // One read before the plan, and one after each command.
        #expect(page.elementReads == 3)
    }

    /// A STEP THAT REFUSES STOPS THE PLAN, and the rest say they never ran.
    @Test func aPlanStopsAtItsFirstRefusal() async {
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), hands: hands)
        let plan = PageInteractionPlan.of([
            .click(.init(location: .target("nothing of the sort"))),
            .click(.init(location: .target("How to choose touring boots"))),
        ])
        let outcome = await engine.act(plan, in: BrowsingFixtures.target())

        #expect(!outcome.ok)
        #expect(hands.clicks.isEmpty)
        #expect(outcome.receipts.count == 2)
        #expect(outcome.receipts[1].delivery == .notAttempted)
    }

    /// SOMEBODY ELSE TAKING THE MACHINE STOPS THE PLAN WHERE IT IS.
    @Test func losingTheFrontStopsThePlanAndSaysWhere() async {
        var stage = FakeStage()
        stage.keepsFocus = false
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), hands: hands, stage: stage)
        let outcome = await engine.pressOnPage(
            "How to choose touring boots", in: BrowsingFixtures.target())

        #expect(hands.clicks.isEmpty)
        #expect(outcome.receipts.first?.delivery == .interrupted)
        #expect(!outcome.landed)
    }

    /// A DRY RUN TOUCHES NOTHING AND SAYS WHAT IT WOULD HAVE DONE.
    @Test func aDryRunActsOnNothing() async {
        let hands = FakeHands()
        let keys = FakeKeys()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [results()]), hands: hands, keys: keys, dryRun: true)
        let outcome = await engine.pressOnPage(
            "How to choose touring boots", in: BrowsingFixtures.target())
        #expect(hands.clicks.isEmpty)
        #expect(keys.typed.isEmpty)
        #expect(outcome.spoken.contains("would have"))
    }

    // MARK: - Scrolling to something

    /// WHAT IS BELOW THE FOLD IS STILL ON THE PAGE. One read and a refusal would be
    /// refusing something that is plainly there.
    @Test func scrollingLooksAgainBeforeGivingUp() async {
        let empty = BrowsingFixtures.page([
            (role: "AXLink", label: "Something near the top", affordance: .press),
        ])
        let hands = FakeHands()
        let page = FakePage(pages: [empty, empty, results()])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]), page: page, hands: hands)
        let outcome = await engine.scrollToOnPage(
            "How to choose touring boots", in: BrowsingFixtures.target())

        #expect(outcome.ok)
        #expect(outcome.landed)
        #expect(hands.scrolls.count == 2)
        #expect(hands.scrolls.allSatisfy { $0 < 0 })
    }

    /// AND IT STOPS RATHER THAN SCROLLING FOREVER.
    @Test func scrollingIsBounded() async {
        let empty = BrowsingFixtures.page([
            (role: "AXLink", label: "Something near the top", affordance: .press),
        ])
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [empty]), hands: hands)
        let outcome = await engine.scrollToOnPage("a thing that is not there", in: BrowsingFixtures.target())
        #expect(!outcome.ok)
        #expect(hands.scrolls.count == BrowserEngine.scrollAttempts)
    }
}

@Suite struct WebSearchRecipeTests {

    private func resultsPage() -> (elements: [AXScreenElement], map: PageMapSummary) {
        BrowsingFixtures.page([
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXLink", label: "The best touring boots this year", affordance: .press),
            (role: "AXLink", label: "How to choose touring boots", affordance: .press),
        ], group: (kind: "row", title: "Results"))
    }

    /// THE QUERY IS TYPED, NOT AUTHORED AS AN ADDRESS.
    @Test func theQueryIsTypedIntoTheAddressBar() async {
        let shell = FakeShell([
            BrowsingFixtures.shell(title: "Home", url: "https://example.com/"),
            BrowsingFixtures.shell(title: "boots — results", url: "https://example.com/?q=alpine+touring+boots"),
        ])
        let engine = BrowsingFixtures.engine(
            shell: shell, page: FakePage(pages: [resultsPage()]))
        _ = await engine.searchWeb(
            "alpine touring boots", in: BrowsingFixtures.target(), open: nil,
            deadline: nil)
        #expect(shell.opened == ["alpine touring boots"])
    }

    /// A BROWSER THAT WENT SOMEWHERE ELSE IS A NAMED REFUSAL — inline completion turning
    /// a half-typed query into somebody's history is the only way to notice this.
    @Test func aCompletedAddressIsRefusedNotReportedAsResults() async {
        let shell = FakeShell([
            BrowsingFixtures.shell(title: "Home", url: "https://example.com/"),
            BrowsingFixtures.shell(title: "A Bank", url: "https://bank.example/login"),
        ])
        let engine = BrowsingFixtures.engine(
            shell: shell, page: FakePage(pages: [resultsPage()]))
        let outcome = await engine.searchWeb(
            "alpine touring boots", in: BrowsingFixtures.target(), open: nil, deadline: nil)
        #expect(!outcome.ok)
        #expect(outcome.spoken.contains("went somewhere else"))
    }

    /// A DOTTED WORD IS AN ADDRESS TO THAT FIELD, and guessing which was meant is worse
    /// than asking.
    @Test func aBareSiteNameIsNotSearchedFor() async {
        let shell = FakeShell([BrowsingFixtures.shell()])
        let engine = BrowsingFixtures.engine(
            shell: shell, page: FakePage(pages: [resultsPage()]))
        let outcome = await engine.searchWeb(
            "example.com", in: BrowsingFixtures.target(), open: nil, deadline: nil)
        #expect(!outcome.ok)
        #expect(shell.opened.isEmpty)
    }

    /// THE RANKING NEVER RETURNS NOTHING. "The first one" is a real request.
    @Test func theRankingAlwaysChoosesForANonEmptyPage() {
        let page = resultsPage()
        let roster = PageRoster(elements: page.elements, map: page.map)
        let results = WebSearchRecipe.admitted(in: roster)
        #expect(results.count == 3)
        #expect(WebSearchRecipe.choose(nil, among: results, in: roster)?.label
            == "Alpine touring boots reviewed")
        #expect(WebSearchRecipe.choose("the second one", among: results, in: roster)?.label
            == "The best touring boots this year")
        #expect(WebSearchRecipe.choose("the last one", among: results, in: roster)?.label
            == "How to choose touring boots")
        #expect(WebSearchRecipe.choose("how to choose", among: results, in: roster)?.label
            == "How to choose touring boots")
        // A phrase matching nothing still opens the top result.
        #expect(WebSearchRecipe.choose("helicopters", among: results, in: roster)?.label
            == "Alpine touring boots reviewed")
    }

    /// PAGE CHROME IS NOT A RESULT — and neither is the query echoed back.
    @Test func chromeCallsToActionAndTheQueryItselfAreNotResults() {
        let page = BrowsingFixtures.page([
            (role: "AXLink", label: "Next", affordance: .press),
            (role: "AXButton", label: "Sign in", affordance: .press),
            // The search box, showing what was typed into it, with the magnifier
            // recognized as a letter. Measured live.
            (role: "AXTextField", label: "alpine touring boots Q", affordance: .press),
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
        ])
        let roster = PageRoster(elements: page.elements, map: page.map)
        let admitted = WebSearchRecipe.admitted(
            in: roster, forQuery: "alpine touring boots")
        #expect(admitted.map(\.label) == ["Alpine touring boots reviewed"])
        // A title that CONTAINS the query and says more is still a result.
        #expect(!WebSearchRecipe.isTheQueryItself(
            "Alpine touring boots reviewed", query: "alpine touring boots"))
        #expect(WebSearchRecipe.isTheQueryItself(
            "alpine touring boots", query: "alpine touring boots"))
    }

    /// A ROW THE PAGE MARKED AS PAID SORTS AFTER THE ORGANIC ONES — read off the page's
    /// own marker, never a list of sites.
    @Test func promotedRowsRankAfterOrganicOnes() {
        var page = BrowsingFixtures.page([
            (role: "AXLink", label: "A promoted result about boots", affordance: .press),
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
        ])
        page.map.annotations[1] = SeenElementAnnotation(
            affordance: .press, labelSource: .textInside, hints: ["sponsored"])
        let roster = PageRoster(elements: page.elements, map: page.map)
        let results = WebSearchRecipe.admitted(in: roster)
        #expect(WebSearchRecipe.choose(nil, among: results, in: roster)?.label
            == "Alpine touring boots reviewed")
    }

    /// ONE SEARCH PER TURN PER QUERY. The second cannot even prove itself.
    @Test func aLandedSearchIsRememberedForTheTurnAndNoLonger() async {
        let memo = BrowserTurnMemo()
        memo.record(query: "alpine touring boots", destination: "Alpine touring boots")
        #expect(memo.landing(for: "alpine touring boots") != nil)
        // Loosely, because the model rarely repeats itself word for word.
        #expect(memo.landing(for: "alpine touring boots please") != nil)
        #expect(memo.landing(for: "something else") == nil)
        memo.beginTurn()
        #expect(memo.landing(for: "alpine touring boots") == nil)
    }
}

@Suite struct BrowserPageReachTests {

    /// A PERSON NAMING SOMETHING IS EVIDENCE THE MAP DOES NOT HAVE.
    ///
    /// The map offers what it is confident about. A phrase reaches further, because
    /// whoever said it can see the screen — but only on an exact naming match, and only
    /// when nothing offered fits.
    @Test func aNamedRowIsReachableEvenWhenItIsNotOffered() async {
        let page = BrowsingFixtures.page([
            (role: "AXLink", label: "Something offered", affordance: .press),
            (role: "AXStaticText", label: "9 languages", affordance: .none),
        ])
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [page]), hands: hands)
        let outcome = await engine.pressOnPage("9 languages", in: BrowsingFixtures.target())

        #expect(hands.clicks.count == 1)
        #expect(outcome.receipts.first?.delivery == .delivered)
    }

    /// AND IT DOES NOT WIDEN THE LISTING. What is offered stays what the map is sure of.
    @Test func reachingFurtherDoesNotChangeWhatIsOffered() async {
        let page = BrowsingFixtures.page([
            (role: "AXLink", label: "Something offered", affordance: .press),
            (role: "AXStaticText", label: "9 languages", affordance: .none),
        ])
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [page]))
        let listing = await engine.readPage(in: BrowsingFixtures.target())
        #expect(listing.spoken.contains("Something offered"))
        #expect(!listing.spoken.contains("9 languages"))
    }

    /// A PHRASE THAT NAMES NOTHING STILL REFUSES. Widening is not guessing.
    @Test func aPhraseThatNamesNothingStillRefuses() async {
        let page = BrowsingFixtures.page([
            (role: "AXLink", label: "Something offered", affordance: .press),
            (role: "AXStaticText", label: "9 languages", affordance: .none),
        ])
        let hands = FakeHands()
        let engine = BrowsingFixtures.engine(
            shell: FakeShell([BrowsingFixtures.shell()]),
            page: FakePage(pages: [page]), hands: hands)
        let outcome = await engine.pressOnPage("the checkout button", in: BrowsingFixtures.target())
        #expect(!outcome.ok)
        #expect(hands.clicks.isEmpty)
    }
}

//
//  PageRouterTests.swift
//  MaryPluginTests
//
//  WHAT: The one arbitration a page goal goes through — what it reaches, what it refuses,
//        and what it says about every row it turned down.
//  OUT:  PageRouter
//  PIN:  THE TRACE IS PART OF THE BEHAVIOUR, NOT A DEBUG AID. A router that picked the
//        right row for the wrong reason is a router that will pick the wrong row on the
//        next page, so these check the disposition and the reason as well as the winner.
//        DETERMINISM IS PINNED, because the whole point of replacing three ladders with
//        one arbitration is that the same read and the same words answer the same way —
//        including when the rows arrive in a different order.
//

import CoreGraphics
import Foundation
import MaryAmbient
import MaryComputerUse
import Testing
@testable import MaryPlugin

/// Fixed vectors, so meaning is a fact of the test rather than of the machine's assets.
private struct ProbeVectorizer: AmbientTextVectorizer {
    let vectors: [String: [Float]]
    func vector(for text: String) -> [Float]? {
        vectors[text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}

private func roster(
    _ rows: [(role: String, label: String, affordance: SeenAffordance)],
    group: (kind: String, title: String?)? = nil,
    source: SeenAffordanceSource = .classifier,
    hints: [Int: [String]] = [:]
) -> PageRoster {
    let page = BrowsingFixtures.page(rows, group: group, source: source, hints: hints)
    return PageRoster(
        elements: page.elements, map: page.map, pageFrame: BrowsingFixtures.pageFrame)
}

/// A store holding one published read, so the semantic term is real.
private func published(
    _ roster: PageRoster, vectors: [String: [Float]]
) -> AmbientElementIndexStore {
    let store = AmbientElementIndexStore(vectorizer: ProbeVectorizer(vectors: vectors))
    AffordanceSlatePublisher.publish(roster, store: store)
    return store
}

@Suite struct PageRouterTests {

    // MARK: - The record

    /// EVERY ROW GETS A DECISION. A row missing from the trace is a row nobody can ask
    /// about, which is the state the three old ladders left every page in.
    @Test func everyRowReceivesADecision() {
        let page = roster([
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXTextField", label: "Search", affordance: .fill),
            (role: "AXStaticText", label: "Terms of service", affordance: SeenAffordance.none),
        ])
        let routed = PageRouter.arbitrate(
            goal: "alpine touring boots reviewed", verb: .press, roster: page)

        #expect(routed.trace.decisions.count == 3)
        #expect(routed.trace.decisions.map(\.id) == [1, 2, 3])
        #expect(routed.trace.decisions.allSatisfy { !$0.reason.isEmpty })
        #expect(routed.winner?.label == "Alpine touring boots reviewed")
        #expect(routed.trace.selected.first?.disposition == .selected)
    }

    /// THE SAME READ AND THE SAME WORDS ANSWER THE SAME WAY — twice, and whatever order
    /// the rows arrive in. Page order is an OUTPUT here, never an input to the verdict.
    @Test func theSameGoalRoutesIdenticallyAndIndependentOfOrder() {
        let rows: [(role: String, label: String, affordance: SeenAffordance)] = [
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXLink", label: "How to choose touring boots", affordance: .press),
            (role: "AXLink", label: "The best touring boots this year", affordance: .press),
        ]
        let first = PageRouter.arbitrate(
            goal: "how to choose", verb: .press, roster: roster(rows))
        let again = PageRouter.arbitrate(
            goal: "how to choose", verb: .press, roster: roster(rows))
        #expect(first.trace == again.trace)

        let reversed = PageRouter.arbitrate(
            goal: "how to choose", verb: .press, roster: roster(rows.reversed()))
        #expect(reversed.winner?.label == first.winner?.label)
    }

    // MARK: - The gate

    @Test func aDisabledOrUnnamedRowSaysWhyItCannotBeReached() {
        var page = roster([
            (role: "AXButton", label: "Continue", affordance: .press),
            (role: "AXButton", label: "button 2", affordance: .press),
        ])
        page.elements[0].isEnabled = false
        page.map.annotations[2] = SeenElementAnnotation(
            affordance: .press, labelSource: .synthesized)

        let routed = PageRouter.arbitrate(goal: "continue", verb: .press, roster: page)

        #expect(routed.trace.decisions[0].disposition == .ineligible)
        #expect(routed.trace.decisions[0].reason == "is unavailable")
        #expect(routed.trace.decisions[1].disposition == .ineligible)
        #expect(routed.trace.decisions[1].reason == "has no name anyone wrote")
        #expect(routed.winner == nil)
    }

    /// NAMING A REAL THING OF THE WRONG SORT IS A DIFFERENT MISTAKE FROM NAMING NOTHING —
    /// where the page offers the right sort and the words named another.
    @Test func fillRefusesALinkByNameWhenThePageHasAField() {
        let page = roster([
            (role: "AXLink", label: "Search our archive", affordance: .press),
            (role: "AXTextField", label: "Your email", affordance: .fill),
        ])
        let filled = PageRouter.arbitrate(
            goal: "search our archive", verb: .fill, roster: page)
        #expect(filled.refusal == .notFillable("search our archive"))
        #expect(filled.trace.decisions[0].reason == "isn't something I can type into")
    }

    /// AND WHERE THE READING FOUND NO FIELD AT ALL, a named row is a candidate instead.
    ///
    /// MEASURED ON A LIVE SITE whose search box the classifier called static text: the
    /// row said "Search or ask a question", and the lane could not type into it. As a
    /// candidate it must still earn the higher floor — naming part of it does that; a
    /// scattering of its words does not, and live it was MEANING that carried it (see
    /// `PageRouterSemanticTests`), which is the whole reason the floor is not the
    /// naming ladder alone.
    @Test func fillFallsBackToNamedRowsWhenNoFieldWasOffered() {
        let page = roster([
            (role: "AXLink", label: "Search or ask a question", affordance: .press),
        ])
        let named = PageRouter.arbitrate(goal: "search or ask", verb: .fill, roster: page)
        #expect(named.winner?.label == "Search or ask a question")
        #expect(named.trace.selected.first?.evidence.lexicalBasis == .contained)

        let scattered = PageRouter.arbitrate(
            goal: "ask search", verb: .fill, roster: page)
        #expect(scattered.winner == nil)
        #expect(scattered.trace.decisions[0].evidence.lexicalBasis == .allWords)
    }

    /// AND MEANING IS WHAT CARRIED IT LIVE — a candidate the words only scatter across is
    /// reached when the goal and the row mean the same thing.
    @Test func meaningCarriesACandidateTheWordsOnlyScatter() {
        let page = roster([
            (role: "AXLink", label: "Search or ask a question", affordance: .press),
        ])
        let store = published(page, vectors: [
            "ask search": [1, 0],
            "search or ask a question": [1, 0],
            "link labelled search or ask a question": [1, 0],
        ])
        let routed = PageRouter.arbitrate(
            goal: "ask search", verb: .fill, roster: page, store: store)
        #expect(routed.winner?.label == "Search or ask a question")
    }

    @Test func adjustRefusesAButton() {
        let page = roster([
            (role: "AXButton", label: "Volume control", affordance: .press),
            (role: "AXSlider", label: "Playback position", affordance: .adjust),
        ])
        let adjusted = PageRouter.arbitrate(
            goal: "volume control", verb: .adjust, roster: page)
        #expect(adjusted.refusal == .notAdjustable("volume control"))
    }

    /// AND AN ORDINAL NAMING A KIND THE PAGE HAS NONE OF IS A MISS, not the top of an
    /// unrelated list. Measured: "the first video" on a page whose rows the reading
    /// classified as nothing counted them at large and answered with a search box.
    @Test func anOrdinalNamingAnAbsentKindReachesNothing() {
        let page = roster([
            (role: "AXLink", label: "Some ordinary link", affordance: .press),
            (role: "AXLink", label: "Another ordinary link", affordance: .press),
        ])
        let routed = PageRouter.arbitrate(
            goal: "the first video", verb: .press, roster: page)
        #expect(routed.winner == nil)
        #expect(routed.refusal == .elementNotFound("the first video"))
    }

    // MARK: - The naming rungs

    @Test func anExactNameOutranksContainment() {
        let page = roster([
            (role: "AXLink", label: "Boots", affordance: .press),
            (role: "AXLink", label: "Boots for winter walking", affordance: .press),
        ])
        let routed = PageRouter.arbitrate(goal: "boots", verb: .press, roster: page)
        #expect(routed.winner?.label == "Boots")
        #expect(routed.trace.selected.first?.evidence.lexicalBasis == .exact)
        // AND THE ROW THE WORDS NEVER REACHED IS NOT "OUTRANKED" — nothing about it
        // answered, which is a different sentence from having been beaten.
        #expect(routed.trace.decisions[1].disposition == .belowFloor)
    }

    /// A SPOKEN POSITION COUNTS THE ELIGIBLE POOL, WITHIN ITS KIND — the same counting the
    /// listing speaks, so what a person reads back resolves to what they read.
    @Test func aSpokenOrdinalCountsWithinItsKind() {
        let page = roster([
            (role: "AXButton", label: "Some button", affordance: .press),
            (role: "AXLink", label: "Fred again.. Boiler Room · 1:02:33", affordance: .press),
            (role: "AXLink", label: "Fred again.. Live at the roof · 4:11", affordance: .press),
        ])
        let routed = PageRouter.arbitrate(
            goal: "the second video", verb: .press, roster: page)
        #expect(routed.winner?.label == "Fred again.. Live at the roof · 4:11")
        #expect(routed.trace.selected.first?.evidence.lexicalBasis == .ordinal)
        #expect(routed.trace.selected.first?.reason == "is at the position that was asked for")
    }

    /// TWO ROWS THE EVIDENCE CANNOT SEPARATE STAY TWO ROWS.
    @Test func twoRowsThatAnswerEquallyAreAQuestion() {
        let page = roster([
            (role: "AXLink", label: "Watch now", affordance: .press),
            (role: "AXLink", label: "Watch now", affordance: .press),
        ])
        let routed = PageRouter.arbitrate(goal: "watch now", verb: .press, roster: page)

        #expect(routed.winner == nil)
        #expect(routed.trace.rivals.count == 2)
        if case .ambiguousElement(let phrase, let rivals) = routed.refusal {
            #expect(phrase == "watch now")
            #expect(rivals.count == 2)
        } else {
            Issue.record("expected an ambiguity, got \(String(describing: routed.refusal))")
        }
    }

    // MARK: - Candidates

    /// A ROW THE MAP NAMED AND DID NOT OFFER is reachable when the words name it exactly —
    /// the classifier trades recall for precision, and whoever spoke can see the screen.
    @Test func aCandidateIsReachableByAnExactNameAndNotByAWeakPhrase() {
        let page = roster([
            (role: "AXLink", label: "Fred again.. - Rooftop Live - YouTube",
             affordance: SeenAffordance.none),
        ])
        let named = PageRouter.arbitrate(
            goal: "Fred again.. - Rooftop Live - YouTube", verb: .press, roster: page)
        #expect(named.winner?.label == "Fred again.. - Rooftop Live - YouTube")

        // Every word present, scattered — enough for an offered row, and deliberately
        // not enough for one the reading itself was unsure of.
        let loose = PageRouter.arbitrate(
            goal: "rooftop youtube", verb: .press, roster: page)
        #expect(loose.winner == nil)
        #expect(loose.trace.decisions[0].disposition == .belowFloor)
    }

    /// NOTHING BEHIND A DIALOG CAN BE REACHED WHILE IT IS THERE.
    @Test func anOverlayDemotesWhatIsBehindIt() {
        var page = roster([
            (role: "AXButton", label: "Accept all cookies", affordance: .press),
            (role: "AXLink", label: "Accept all terms and conditions", affordance: .press),
        ])
        page.map.groups = [
            SeenGroup(id: 9, kind: "overlay", title: "Consent", memberOrdinals: [1]),
        ]
        let routed = PageRouter.arbitrate(goal: "accept all", verb: .press, roster: page)

        #expect(routed.winner?.label == "Accept all cookies")
        #expect(routed.trace.decisions[1].evidence.structure < 0)
        #expect(routed.trace.decisions[1].reason.contains("behind the dialog")
            || routed.trace.decisions[1].disposition == .outranked)
    }
}

@Suite struct PageRouterSemanticTests {

    /// NO ROW IS DECIDED BY PAGE ORDER WHEN MEANING HAS AN OPINION. The row further down
    /// wins because it answers, and it still wins when the rows arrive the other way up.
    @Test func meaningDecidesRatherThanPosition() {
        let rows: [(role: String, label: String, affordance: SeenAffordance)] = [
            (role: "AXLink", label: "Terms and conditions", affordance: .press),
            (role: "AXLink", label: "Skip advertisement", affordance: .press),
        ]
        let vectors: [String: [Float]] = [
            "skip the ad": [1, 0],
            "skip advertisement": [0.99, 0.14],
            "link labelled skip advertisement": [0.99, 0.14],
            "terms and conditions": [0, 1],
            "link labelled terms and conditions": [0, 1],
        ]
        for ordering in [rows, rows.reversed()] {
            let page = roster(ordering)
            let routed = PageRouter.arbitrate(
                goal: "skip the ad", verb: .press, roster: page,
                store: published(page, vectors: vectors))
            #expect(routed.winner?.label == "Skip advertisement")
        }
    }

    /// AND A MEANING NOBODY CAN CALL A MATCH REACHES NOTHING.
    @Test func aWinnerBelowTheFloorIsBelowFloor() {
        let page = roster([
            (role: "AXLink", label: "Terms and conditions", affordance: .press),
        ])
        let vectors: [String: [Float]] = [
            "skip the ad": [1, 0],
            "terms and conditions": [0.2, 0.98],
            "link labelled terms and conditions": [0.2, 0.98],
        ]
        let routed = PageRouter.arbitrate(
            goal: "skip the ad", verb: .press, roster: page,
            store: published(page, vectors: vectors))

        #expect(routed.winner == nil)
        #expect(routed.trace.decisions[0].disposition == .belowFloor)
        #expect(routed.refusal == .elementNotFound("skip the ad"))
    }

    /// TWO MEANINGS A HAIR APART ARE NOT A DECISION.
    @Test func meaningsWithinTheMarginStayRivals() {
        let page = roster([
            (role: "AXLink", label: "Dismiss this promotion", affordance: .press),
            (role: "AXLink", label: "Hide this banner", affordance: .press),
        ])
        let vectors: [String: [Float]] = [
            "skip the ad": [1, 0],
            "dismiss this promotion": [0.9, 0.435],
            "link labelled dismiss this promotion": [0.9, 0.435],
            "hide this banner": [0.899, 0.438],
            "link labelled hide this banner": [0.899, 0.438],
        ]
        let routed = PageRouter.arbitrate(
            goal: "skip the ad", verb: .press, roster: page,
            store: published(page, vectors: vectors))

        #expect(routed.winner == nil)
        #expect(routed.trace.rivals.count == 2)
    }

    /// THE LANE THAT ACTS WITHOUT ASKING STILL SEES ONLY WHAT THE READING WAS SURE OF.
    /// `AffordanceProbe` dispatches `act_on_screen` deterministically above its own floor,
    /// so a row the map merely NAMED must be invisible to it however well it scores.
    @Test func theProbeNeverNamesACandidate() {
        let page = roster([
            (role: "AXLink", label: "Skip advertisement", affordance: SeenAffordance.none),
        ])
        let store = published(page, vectors: [
            "skip the ad": [1, 0],
            "skip advertisement": [1, 0],
            "link labelled skip advertisement": [1, 0],
        ])
        // The router reaches it...
        #expect(PageRouter.arbitrate(
            goal: "skip advertisement", verb: .press, roster: page, store: store).winner != nil)
        // ...and the probe does not.
        #expect(AffordanceProbe.candidate(for: "skip the ad", store: store) == nil)
    }
}

@Suite struct PageRouterResultTests {

    /// THE MEASURED PAGE, AND WHY IT IS REFUSED.
    ///
    /// A live search read 80 rows and marked none of them actionable. What the reading
    /// actually held was the site's own furniture — a region picker, a navigation strip,
    /// thirteen related-search suggestions, the query echoed twice — and the real titles
    /// BROKEN ACROSS ROWS. Every generic ranking tried against that pool picked a
    /// different piece of furniture, because there was no answer in it to pick. So the
    /// page is reported as unreadable, and every row says which kind of thing it was.
    private func measuredPage() -> PageRoster {
        var page = roster([
            (role: "AXLink", label: "E News • Videos # Web + Al Chat & Images",
             affordance: SeenAffordance.none),
            (role: "AXLink", label: "https://www.youtube.com › watch?v=6MAzUT1YhWE",
             affordance: SeenAffordance.none),
            (role: "AXLink", label: "Search region: United States (English)",
             affordance: SeenAffordance.none),
            (role: "AXLink", label: "again.. - Rooftop Live (Arun's Roof,",
             affordance: SeenAffordance.none),
            (role: "AXLink", label: "Searches related to fred again video on",
             affordance: SeenAffordance.none),
        ])
        // Every row a band, which is what the reading actually produced.
        page.map.groups = [
            SeenGroup(id: 0, kind: "band", title: nil, memberOrdinals: [1, 2, 3, 4, 5]),
        ]
        return page
    }

    @Test func aPageWhoseAnswersWereNeverOfferedIsSaidToBeUnreadable() {
        let routed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "fred again video on youtube"),
            roster: measuredPage())

        #expect(routed.winner == nil, "nothing on this page may be pressed")
        let reasons = Dictionary(
            uniqueKeysWithValues: routed.trace.decisions.map { ($0.id, $0.reason) })
        #expect(reasons[1] == "was named but sits in no result group")
        #expect(reasons[2] == "is an address, not a title")
        #expect(reasons[3] == "was named but sits in no result group")
        #expect(reasons[4] == "was named but sits in no result group")
        #expect(reasons[5] == "is the query echoed back")
    }

    /// AND THAT SAME UNGROUPED ROW IS REACHED THE MOMENT SOMEBODY NAMES IT — the exact
    /// live counter-case to the refusal above.
    ///
    /// Measured on a real search: an ungrouped band held the real, correctly split
    /// title "Fred again.. | Boiler Room: London - YouTube" beside a "related searches"
    /// suggestion panel that VisionAX had grouped as a card. Naming the real title
    /// exactly used to be refused for the same reason the no-pick guess above is —
    /// "sits in no result group" — even though `.press`/`.fill`/`.adjust` all reach an
    /// ungrouped row on an exact name. This pins that `.openResult` now does too, and
    /// that guessing among the page's furniture is still refused.
    @Test func anExactPickReachesAnUngroupedRealTitleBesideAnUnrelatedCard() {
        var page = roster([
            (role: "AXLink", label: "fred again most famous song",
             affordance: SeenAffordance.none),
            (role: "AXLink", label: "fred again new song", affordance: SeenAffordance.none),
            (role: "AXLink", label: "Fred again.. | Boiler Room: London - YouTube",
             affordance: SeenAffordance.none),
        ])
        page.map.groups = [
            SeenGroup(
                id: 0, kind: "card", title: "related searches",
                memberOrdinals: [1, 2]),
            SeenGroup(id: 1, kind: "band", title: nil, memberOrdinals: [3]),
        ]

        // Naming it exactly reaches it, outranking the grouped suggestion card.
        let named = PageRouter.arbitrate(
            goal: "Boiler Room", verb: .openResult(query: "a fred again video on youtube"),
            roster: page)
        #expect(named.winner?.label == "Fred again.. | Boiler Room: London - YouTube")

        // But with nothing named, the ungrouped row is still not a guess — the grouped
        // card answers the no-pick fallback instead, exactly as before this fix.
        let guessed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "a fred again video on youtube"), roster: page)
        #expect(guessed.winner?.label == "fred again most famous song")
    }

    /// A ROW THAT IS SEVERAL SHORT NAMES JOINED BY SEPARATORS IS A NAVIGATION STRIP.
    ///
    /// Measured on the same page: the site draws its own tabs as one row, long enough and
    /// named well enough to look exactly like an answer. A title that happens to carry a
    /// separator has two segments and a long one, so the same test leaves it alone.
    @Test func aRowOfShortNamesJoinedBySeparatorsIsAStrip() {
        #expect(RowFactsDerivation.isSeparatedStrip("News + AI Chat & Images · Videos · Web"))
        #expect(RowFactsDerivation.isSeparatedStrip("Home • About • Contact • Jobs"))
        #expect(!RowFactsDerivation.isSeparatedStrip(
            "Fred again.. Boiler Room London · 1:02:33"))
        #expect(!RowFactsDerivation.isSeparatedStrip("Alpine touring boots reviewed"))
    }

    /// AND WHERE THE PAGE DOES LAY ITS ANSWERS OUT, the same rows are reachable. The
    /// difference is the page's own structure, which is the only thing vouching for a row
    /// the reading declined to offer.
    @Test func theSameRowsAreReachableWhenThePageGroupsThem() {
        var page = measuredPage()
        page.map.groups = [
            SeenGroup(id: 0, kind: "band", title: nil, memberOrdinals: [1, 2, 5]),
            SeenGroup(id: 1, kind: "row", title: "Results", memberOrdinals: [3, 4]),
        ]
        let routed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "fred again video on youtube"),
            roster: page)
        #expect(routed.winner?.label == "Search region: United States (English)")
    }

    /// A PAGE WITH NOTHING BUT FURNITURE REFUSES rather than pressing a piece of it.
    @Test func aPageOfFurnitureOnlyRefuses() {
        var page = roster([
            (role: "AXTextField", label: "alpine touring boots Q", affordance: .fill),
            (role: "AXButton", label: "Sign in", affordance: .press),
            (role: "AXLink", label: "Next", affordance: .press),
        ])
        page.map.groups = [
            SeenGroup(id: 0, kind: "toolbar", title: nil, memberOrdinals: [1, 2, 3]),
        ]
        let routed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "alpine touring boots"), roster: page)
        #expect(routed.winner == nil)
        #expect(routed.trace.decisions.allSatisfy { $0.disposition == .ineligible })
    }

    /// A ROW THE PAGE MARKED AS PAID SORTS AFTER THE ORGANIC ONES.
    @Test func promotedRowsRankAfterOrganicOnes() {
        let page = roster([
            (role: "AXLink", label: "A promoted result about boots", affordance: .press),
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
        ], group: (kind: "row", title: "Results"), hints: [1: ["sponsored"]])
        let routed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "touring boots"), roster: page)

        #expect(routed.winner?.label == "Alpine touring boots reviewed")
        #expect(routed.trace.decisions[0].reason == "is marked as promoted")
    }

    /// A QUERY THAT NAMES A MEDIUM PREFERS ROWS OF IT — and still answers a page with none.
    @Test func aQueryNamingAVideoPrefersVideosAndStillAnswersWithout() {
        let withVideo = roster([
            (role: "AXLink", label: "Fred again.. — the Guardian profile", affordance: .press),
            (role: "AXLink", label: "Fred again.. Boiler Room London · 1:02:33", affordance: .press),
        ], group: (kind: "row", title: "Results"))
        #expect(withVideo.elements[1].spokenKind == .video, "the fixture must hold a video")
        let routed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "a fred again video on youtube"),
            roster: withVideo)
        #expect(routed.winner?.label == "Fred again.. Boiler Room London · 1:02:33")

        let without = roster([
            (role: "AXLink", label: "Fred again.. — the Guardian profile", affordance: .press),
            (role: "AXLink", label: "Fred again.. tour dates announced", affordance: .press),
        ], group: (kind: "row", title: "Results"))
        let anyway = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "a fred again video on youtube"),
            roster: without)
        #expect(anyway.winner?.label == "Fred again.. — the Guardian profile")
    }

    /// THE RANKING NEVER RETURNS NOTHING FOR A PAGE THAT HAS RESULTS, and a pick that
    /// named nothing says so instead of pretending it matched.
    @Test func aPickThatMatchesNothingFallsBackAndSaysSo() {
        let page = roster([
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXLink", label: "The best touring boots this year", affordance: .press),
            (role: "AXLink", label: "How to choose touring boots", affordance: .press),
        ], group: (kind: "row", title: "Results"))
        let query = "touring boots"

        #expect(PageRouter.arbitrate(
            goal: "the second one", verb: .openResult(query: query), roster: page)
            .winner?.label == "The best touring boots this year")
        #expect(PageRouter.arbitrate(
            goal: "the last one", verb: .openResult(query: query), roster: page)
            .winner?.label == "How to choose touring boots")
        #expect(PageRouter.arbitrate(
            goal: "how to choose", verb: .openResult(query: query), roster: page)
            .winner?.label == "How to choose touring boots")

        let unmatched = PageRouter.arbitrate(
            goal: "helicopters", verb: .openResult(query: query), roster: page)
        #expect(unmatched.winner?.label == "Alpine touring boots reviewed")
        #expect(unmatched.trace.goalUnmatched)
        #expect(unmatched.trace.goal == "helicopters")
    }

    /// PAGE CHROME IS NOT A RESULT — each one named for what it is.
    @Test func chromeCallsToActionAndTheEchoAreNamedForWhatTheyAre() {
        let page = roster([
            (role: "AXLink", label: "Home", affordance: .press),
            (role: "AXButton", label: "Sign in", affordance: .press),
            (role: "AXTextField", label: "alpine touring boots Q", affordance: .press),
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
        ], group: (kind: "row", title: "Results"))
        let routed = PageRouter.arbitrate(
            goal: "", verb: .openResult(query: "alpine touring boots"), roster: page)

        #expect(routed.winner?.label == "Alpine touring boots reviewed")
        let reasons = Dictionary(
            uniqueKeysWithValues: routed.trace.decisions.map { ($0.id, $0.reason) })
        #expect(reasons[1] == "is too short to be a result")
        #expect(reasons[2] == "is a call to action")
        #expect(reasons[3] == "is the query echoed back")
        #expect(reasons[4] == "is the page's own first answer")
    }
}

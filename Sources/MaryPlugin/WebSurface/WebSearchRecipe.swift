//
//  WebSearchRecipe.swift
//  MaryPlugin
//
//  WHAT: Search the web, then open what was asked for — typed into the browser's own
//        address bar, read back from the results, pressed, and proved.
//  IN:   BrowserEngine
//  OUT:  BrowserOutcome
//  PIN:  NO ENGINE IS NAMED, AND NO ADDRESS IS AUTHORED. The query is typed into the
//        address field and the browser searches with whatever the PERSON configured.
//        That is what keeps this file free of a search provider, and it is also the only
//        version that respects a choice somebody already made.
//        THE SETTLED ADDRESS IS THE RECEIPT, AND IT IS NEVER SPOKEN. A browser's address
//        field navigates anything that looks like an address and searches everything
//        else, so the one thing worth checking is whether what came back is actually
//        about the query. Held, compared, discarded.
//        THE RANKING IS THE ROUTER'S, NOT THIS FILE'S. Which row on a results page
//        answers "the first video" is the same question as which row answers "accept all"
//        on a consent wall, asked of the same read with the same evidence — so it is asked
//        in one place. What survives here is what is particular to SEARCHING: typing the
//        query into the browser's own field, proving the browser actually searched for it,
//        and remembering where the turn already landed.
//        AND IT STILL NEVER RETURNS NOTHING FOR A PAGE THAT HAS RESULTS. "Open the first
//        one" is a real request; a pick that matches nothing falls back to the page's own
//        first answer and SAYS SO, rather than refusing to choose.
//        ONE SEARCH PER TURN PER QUERY. The second identical search cannot even prove
//        itself: the address and the title do not change, so it reports failure for work
//        that already succeeded.
//

import Foundation
import MaryComputerUse
import MaryFoundation

public enum WebSearchRecipe {

    /// How long the results have to draw before they are read.
    static let resultsSettle = Duration.milliseconds(900)
    /// A row shorter than this is chrome — a "next" or a breadcrumb, not a result.
    static let minimumResultLabel = 12

    public static func searchAndOpen(
        _ query: String,
        pick: String?,
        in target: BrowserTarget,
        engine: BrowserEngine,
        memo: BrowserTurnMemo = .shared,
        deadline: Date? = nil
    ) async -> BrowserOutcome {
        let asked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else {
            return BrowserOutcome(ok: false, spoken: "Tell me what to search for.")
        }
        // ALREADY DONE THIS TURN. Saying so is the whole answer — searching again would
        // land on the same page and be unable to prove it.
        if let landing = memo.landing(for: asked) {
            return BrowserOutcome(
                ok: true,
                spoken: "I already opened \(landing.destination) for that.",
                landed: true)
        }
        // A BARE DOTTED WORD IS AN ADDRESS TO THIS FIELD, not a query, and the two do
        // very different things. Say which one was meant rather than guessing.
        if SpokenAddress.looksLikeAnAddress(asked) {
            return BrowserOutcome(
                ok: false,
                spoken: "\"\(asked)\" looks like a site rather than something to search for — say \"go to\" and I'll open it.")
        }

        let opened = await engine.navigate(.open(asked), in: target)
        guard opened.ok, let shell = opened.shell else { return opened }
        guard searched(for: asked, shell: shell) else {
            return await engine.refusing(.searchCompletedElsewhere)
        }

        await engine.settleForResults()
        let read = await engine.readPage(in: target)
        guard read.ok else { return read }
        let roster = PageRoster(
            elements: read.elements, map: read.map ?? PageMapSummary(),
            pageFrame: read.shell?.pageFrame ?? .zero)

        let routed = await engine.arbitrate(
            pick ?? "", verb: .openResult(query: asked), in: roster)
        guard let choice = routed.winner else {
            if let refusal = routed.refusal, case .ambiguousElement = refusal {
                return await engine.refusing(refusal)
            }
            return BrowserOutcome(
                ok: true, spoken: "I searched for \(asked), but I can't make out any results.",
                shell: read.shell, elements: read.elements, map: read.map, landed: true)
        }
        // A PICK THAT MATCHED NOTHING IS SAID OUT LOUD. The page's first answer is a
        // better outcome than a refusal, and pretending it was what they named is not.
        let unmatched = routed.trace.goalUnmatched
            ? "I couldn't match \"\(pick ?? "")\", so I opened the first result. "
            : ""

        let pressed = await engine.pressOnPage(choice.label, in: target, deadline: deadline)
        guard pressed.landed, let destination = pressed.shell?.title ?? pressed.shell?.siteName
        else {
            let listing = PageListing.tail(roster)
            return BrowserOutcome(
                ok: true,
                spoken: "\(unmatched)I searched for \(asked). \(listing)",
                shell: read.shell, elements: read.elements, map: read.map,
                receipts: pressed.receipts,
                landed: true)
        }
        memo.record(query: asked, destination: destination)
        guard !unmatched.isEmpty else { return pressed }
        var spoken = pressed
        spoken.spoken = unmatched + pressed.spoken
        return spoken
    }

    // MARK: - The receipt

    /// Did the browser actually search for what was typed?
    ///
    /// The address is READ AS EVIDENCE AND DISCARDED — never spoken, never returned.
    /// Inline completion can turn a half-typed query into somebody's history entry, and
    /// this is the only place that would ever notice.
    static func searched(for query: String, shell: WebSurfaceAX.Reading) -> Bool {
        guard let url = shell.url, !url.isEmpty else {
            // NO ADDRESS TO CHECK IS NOT A FAILURE. A browser that does not publish one
            // is a browser this cannot judge, and refusing everything it does would be
            // worse than trusting the settle that already happened.
            return true
        }
        let folded = fold(query)
        guard !folded.isEmpty else { return true }
        let haystack = fold(url) + " " + fold(shell.title ?? "")
        if haystack.contains(folded) { return true }
        // Long queries survive re-ordering and truncation badly; the distinctive words
        // are the evidence, the same way a spoken address is matched.
        let words = folded.split(separator: " ").filter { $0.count >= 4 }
        guard !words.isEmpty else { return true }
        let found = words.filter { haystack.contains($0) }.count
        return found * 2 >= words.count
    }

    /// The one folding this lane compares with — the router's, so a query judged a
    /// match here and an echo there cannot disagree about what the words were.
    static func fold(_ value: String) -> String { PageRouter.fold(value) }
}

extension BrowserEngine {
    /// A refusal from outside the actor's own body.
    func refusing(_ refusal: BrowserRefusal) -> BrowserOutcome {
        refuse(refusal)
    }

    /// Time for results to draw before they are read.
    func settleForResults() async {
        await seams.sleep(WebSearchRecipe.resultsSettle)
    }
}

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
            // THE RECEIPT IS THE LANDING IT REMEMBERS. `landed` rests on evidence
            // even here: this turn already proved the navigation, and reporting
            // the work as done without saying what proved it is the hand-set
            // claim this recipe used to make three times over.
            return BrowserOutcome(
                ok: true,
                spoken: "I already opened \(landing.destination) for that.",
                receipts: [PageCommandReceipt(
                    sourceIndex: 0, kind: .navigate, target: nil,
                    delivery: .delivered,
                    effect: .verified(.navigation(title: landing.destination)))],
                landed: true)
        }
        // A BARE DOTTED WORD IS AN ADDRESS TO THIS FIELD, not a query, and the two do
        // very different things. Say which one was meant rather than guessing.
        if SpokenAddress.looksLikeAnAddress(asked) {
            return BrowserOutcome(
                ok: false,
                spoken: "\"\(asked)\" looks like a site rather than something to search for — say \"go to\" and I'll open it.")
        }

        // THE RESULTS MAY ALREADY BE IN FRONT, and typing the same query again
        // cannot prove anything.
        //
        // PIN: MEASURED — a second run of the same journey typed the query into
        // a browser already showing that query's results, nothing changed
        // (nothing could), and the whole navigation budget was spent before
        // reporting "the page didn't finish loading" about a page that was
        // exactly where it was asked to be. This is `settle`'s arrival rule one
        // level up: the receipt is the page in front, and the same evidence
        // proves it — the browser's own title and address, asked of the query.
        // AND ONLY RESULTS THIS ENGINE SEARCHED FOR. `searched` is the check
        // made AFTER typing, where the address is known to be a search; asked
        // of whatever page happens to be in front it is far too loose — measured
        // in round 8, a product page titled with two of the query's three words
        // was taken as the results for it, and "search the web for alpine
        // touring boots" typed nothing and reported a shop. The page in front
        // is the results when this engine put them there.
        let standing = await engine.readShell(target)
        let opened: BrowserOutcome
        if let here = standing.shell, await engine.resultsStanding(for: asked, shell: here) {
            await engine.emitJourney("already showing results for that")
            let receipt = PageCommandReceipt(
                sourceIndex: 0, kind: .navigate, target: nil, delivery: .delivered,
                effect: .verified(.navigation(title: here.title ?? "")))
            // ON THE STREAM AS WELL AS IN THE OUTCOME — see `settle`.
            await engine.emit(.receipt(receipt))
            opened = BrowserOutcome(
                ok: true, spoken: standing.spoken, shell: here,
                receipts: [receipt], landed: true)
        } else {
            opened = await engine.navigate(.open(asked), in: target)
        }
        guard opened.ok, let shell = opened.shell else { return opened }
        guard searched(for: asked, shell: shell) else {
            return await engine.refuse(.searchCompletedElsewhere)
        }

        await engine.settleForResults(in: target)
        let read = await engine.readPage(in: target)
        guard read.ok else { return read }
        // WHAT THIS PAGE IS A LIST OF ANSWERS TO — remembered AFTER the read.
        //
        // PIN: THE READ ITSELF WIPES THIS. `readPage` retracts the slate before
        // it looks, and the retraction clears the remembered query with it, for
        // the good reason that both describe a page that may be gone. Noting the
        // query first was therefore noting it into the thing about to be cleared,
        // and the next "open the second one" routed as a bare press over the
        // whole page — measured on two trips. Order is the whole fix.
        await engine.noteResultQuery(asked)
        // THE READ'S OWN ROWS, NOT THE AX-SHAPED SHIM.
        //
        // PIN: A ROSTER REBUILT FROM `elements` LOSES WHAT ONLY A ROW CARRIES.
        // `AXScreenElement` is the old pair kept for the callers that still read
        // it, and a row's site, its slider range and its provenance are not in
        // it — so rebuilding here handed the router a page whose results all
        // went nowhere in particular. MEASURED: "watch a fireplace video on
        // youtube" opened a related-search suggestion literally spelled
        // "youtube fireplace 24 hours", because the site gate had no sites to
        // gate on. The engine published the real rows a moment ago; they are
        // what the route is argued from.
        let roster = await engine.snapshot().lastRoster ?? PageRoster(
            elements: read.elements, map: read.map ?? PageMapSummary(),
            pageFrame: read.shell?.pageFrame ?? .zero)

        // A BARE SEARCH SHOWS THE RESULTS; IT DOES NOT WALK INTO ONE.
        //
        // PIN: THE PACKAGE ALREADY SAID SO, AND THE ENGINE DID OTHERWISE.
        // `browsing.mary` declares this verb as "show the results, opening one
        // when the person named which" — and this arbitrated `pick ?? ""` with
        // `.openResult`, whose no-goal fallback selects the page's first answer
        // by design. So "search the web for X" opened whatever happened to be
        // first, having been asked only to search. Measured live: 5.5s, of which
        // the second read and the second arbitration were spent walking into a
        // result nobody named. With no pick there is nothing to arbitrate, and
        // the listing is the answer.
        guard let pick, !pick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BrowserOutcome(
                ok: true,
                spoken: "I searched for \(asked). \(PageListing.tail(roster))",
                shell: read.shell, elements: read.elements, map: read.map,
                receipts: opened.receipts,
                landed: opened.landed)
        }

        let routed = await engine.arbitrate(
            pick, verb: .openResult(query: asked), in: roster)
        guard let choice = routed.winner else {
            if let refusal = routed.refusal, case .ambiguousElement = refusal {
                return await engine.refuse(refusal)
            }
            // THE SEARCH LANDED EVEN THOUGH THE RESULTS DID NOT READ. What is
            // proven is the navigation that carried it; the reading is a separate
            // claim, and this sentence is careful not to make it.
            return BrowserOutcome(
                ok: true, spoken: "I searched for \(asked), but I can't make out any results.",
                shell: read.shell, elements: read.elements, map: read.map,
                receipts: opened.receipts,
                landed: opened.landed)
        }
        // A PICK THAT MATCHED NOTHING IS SAID OUT LOUD. The page's first answer is a
        // better outcome than a refusal, and pretending it was what they named is not.
        let unmatched = routed.trace.goalUnmatched
            ? "I couldn't match \"\(pick)\", so I opened the first result. "
            : ""

        let pressed = await engine.pressOnPage(choice.label, in: target, deadline: deadline)
        guard pressed.landed, let destination = pressed.shell?.title ?? pressed.shell?.siteName
        else {
            let listing = PageListing.tail(roster)
            return BrowserOutcome(
                ok: true,
                spoken: "\(unmatched)I searched for \(asked). \(listing)",
                shell: read.shell, elements: read.elements, map: read.map,
                // The search's navigation is proven; the press's receipts say for
                // themselves what became of it.
                receipts: opened.receipts + pressed.receipts,
                landed: opened.landed)
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

    /// The one folding this lane compares with — the SEAL's, so a query judged a
    /// match here and an echo there cannot disagree about what the words were.
    static func fold(_ value: String) -> String { RowFactsDerivation.folded(value) }
}

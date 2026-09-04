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
//        THE RANKING NEVER RETURNS NOTHING FOR A PAGE THAT HAS RESULTS. Name, then
//        meaning, then the order the page put them in — because "open the first one" is
//        a real request and a refusal to choose is a worse answer than the top result.
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

        let results = admitted(in: roster, forQuery: asked)
        guard !results.isEmpty else {
            return BrowserOutcome(
                ok: true, spoken: "I searched for \(asked), but I can't make out any results.",
                shell: read.shell, elements: read.elements, map: read.map, landed: true)
        }
        guard let choice = choose(pick, among: results, in: roster) else {
            // Cannot happen for a non-empty pool; the ladder's last rung is page order.
            return read
        }

        let pressed = await engine.pressOnPage(choice.label, in: target, deadline: deadline)
        guard pressed.landed, let destination = pressed.shell?.title ?? pressed.shell?.siteName
        else {
            let listing = PageListing.tail(roster)
            return BrowserOutcome(
                ok: true,
                spoken: "I searched for \(asked). \(listing)",
                shell: read.shell, elements: read.elements, map: read.map,
                receipts: pressed.receipts,
                landed: true)
        }
        memo.record(query: asked, destination: destination)
        return pressed
    }

    // MARK: - The results

    /// Rows that could be a result: something to press, with a name long enough to be
    /// one, and not the page's own chrome.
    public static func admitted(
        in roster: PageRoster, forQuery query: String = ""
    ) -> [AXScreenElement] {
        roster.actionable.filter { element in
            guard element.isEnabled else { return false }
            guard element.label.count >= minimumResultLabel else { return false }
            guard roster.annotation(for: element)?.labelSource.isReal != false else { return false }
            guard !PageElementKindDerivation.isCallToAction(element.label) else { return false }
            return !isTheQueryItself(element.label, query: query)
        }
    }

    /// Is this row just the query, echoed back?
    ///
    /// PIN: A RESULTS PAGE SHOWS YOU WHAT YOU ASKED FOR, in its own search box, and that
    /// row is pressable, well named and the right length — it looks exactly like the top
    /// result to every test above. Measured live: a search for "swift concurrency"
    /// opened the search field, whose label read "swift concurrency Q" with the
    /// magnifier recognized as a letter. A real title CONTAINS the query and says more;
    /// this one says the query and stops, so what is left after removing it is the test.
    static func isTheQueryItself(_ label: String, query: String) -> Bool {
        let folded = fold(label).replacingOccurrences(of: " ", with: "")
        let asked = fold(query).replacingOccurrences(of: " ", with: "")
        guard !asked.isEmpty, folded.contains(asked) else { return false }
        return folded.count - asked.count < queryEchoSlack
    }

    /// How much more than the query a row must say to be a result rather than the box
    /// the query was typed into. Two characters covers a recognized magnifier or a
    /// trailing punctuation mark.
    static let queryEchoSlack = 3

    /// Which one to open.
    ///
    /// PIN: THREE RUNGS, AND THE LAST ONE ALWAYS ANSWERS. A phrase names it; failing
    /// that, the kind it named narrows the pool ("the first video" among videos); failing
    /// that, the page's own order decides. Promoted rows sort after organic ones — read
    /// off the page's own marker, never a list of sites.
    public static func choose(
        _ pick: String?, among results: [AXScreenElement], in roster: PageRoster
    ) -> AXScreenElement? {
        let ordered = organicFirst(results, in: roster)
        guard let pick, !pick.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ordered.first
        }
        // 1 — the words.
        if case .one(let element) = ScreenElementResolver.resolve(
            phrase: pick, in: ordered, preferShortestOnTie: false) {
            return element
        }
        // 2 — the kind the phrase named, in page order.
        if let kind = PageElementKindDerivation.offeredKind(
            namedIn: pick, offering: Set(ordered.compactMap(\.spokenKind))) {
            let ofKind = ordered.filter { $0.spokenKind == kind }
            if let element = at(SpokenOrdinal.value(in: pick), in: ofKind) { return element }
            if let first = ofKind.first { return first }
        }
        // 3 — the order the page put them in.
        if let element = at(SpokenOrdinal.value(in: pick), in: ordered) { return element }
        return ordered.first
    }

    /// A spoken position, counted over a pool. "The last one" counts from the end.
    static func at(_ ordinal: Int?, in pool: [AXScreenElement]) -> AXScreenElement? {
        guard let ordinal, !pool.isEmpty else { return nil }
        if ordinal == -1 { return pool.last }
        guard ordinal >= 1, ordinal <= pool.count else { return nil }
        return pool[ordinal - 1]
    }

    /// Promoted rows after organic ones, each keeping the page's own order.
    static func organicFirst(
        _ results: [AXScreenElement], in roster: PageRoster
    ) -> [AXScreenElement] {
        let promoted = Set(["sponsored", "ad", "ads", "promoted", "advertisement"])
        let marked = results.filter { element in
            (roster.annotation(for: element)?.hints ?? []).contains { promoted.contains($0) }
        }
        guard !marked.isEmpty else { return results }
        let markedIDs = Set(marked.map(\.ordinal))
        return results.filter { !markedIDs.contains($0.ordinal) } + marked
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

    static func fold(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
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

//
//  WatchRecipe.swift
//  MaryPlugin
//
//  WHAT: "Watch a Fred again set on YouTube" — a journey, not a verb: search,
//        choose a result that answers BOTH what and where, and if the results
//        offer no such thing, go to the site the person named and search there.
//  IN:   BrowserEngine (the verbs), PageRouter (the choosing)
//  OUT:  BrowserOutcome, and a route recorded for every arbitration on the way
//  PIN:  A JOURNEY IS THE VERBS A PERSON WOULD SAY ONE AT A TIME. Nothing here
//        presses or types by itself: every step is `searchWeb`, `pressOnPage`,
//        `fillOnPage` — already proved, already recorded, already refusing by
//        name — and what this file adds is the DECISION about which step comes
//        next, taken from the reading rather than from a plan written in advance.
//        NO SITE IS NAMED HERE, and none is knowable. Which site the person
//        meant is whatever their own words match among the sites the page's own
//        rows lead to (`PageRouteDomain.siteNamedInGoal`); the second road opens
//        that row and uses the page's own search box, exactly as `site-search`
//        does. A file that knew what YouTube was would be the hard-coding the
//        whole corpus exists to refuse.
//        THE STAGE IS HELD FOR THE WHOLE JOURNEY, once, by the caller.
//

import Foundation
import MaryComputerUse

public enum WatchRecipe {

    /// Which road the journey took, for the trip that judges it.
    public enum Road: String, Sendable, Equatable {
        /// A result on the search page answered, and was opened.
        case results
        /// No result did, so the site's own page was opened and searched.
        case siteSearch
    }

    /// Search for something and open it — preferring, when the words name a
    /// site, a result that goes there.
    public static func watch(
        _ asked: String,
        in target: BrowserTarget,
        engine: BrowserEngine,
        deadline: Date? = nil
    ) async -> BrowserOutcome {
        let query = asked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return BrowserOutcome(ok: false, spoken: "Tell me what to watch.")
        }
        // ROAD ONE: the results, choosing with the person's own words. The pick
        // IS the query, so the router weighs the kind they named ("video") and
        // the site they named against every result on the page.
        let opened = await WebSearchRecipe.searchAndOpen(
            query, pick: query, in: target, engine: engine, deadline: deadline)
        if opened.landed {
            await engine.noteWatchRoad(.results)
            return await spoken(opened, in: target, engine: engine)
        }
        guard opened.ok else { return opened }

        // ROAD TWO: nothing on the results page answered, so go to the site the
        // person named and ask IT. The row that leads there is on the page in
        // front — a site's front door is a result when you search its name.
        guard let roster = await engine.snapshot().lastRoster,
              let site = PageRouter.siteNamed(
                  in: query, verb: .openResult(query: query), among: roster.rows),
              let door = frontDoor(to: site, among: roster.rows)
        else { return opened }

        await engine.emitJourney("no result went to \(site) — opening it instead")
        let arrived = await engine.pressOnPage(door.label, in: target, deadline: deadline)
        guard arrived.landed else { return opened }

        // THE SITE'S OWN BOX, with the site's name taken back out of the words:
        // typing "on youtube" into YouTube's search asks for videos about it.
        let wanted = withoutSite(site, in: query)
        let searched = await engine.fillOnPage(
            nil, text: wanted, submit: true, in: target, deadline: deadline)
        // A SUBMIT THAT DID NOT LAND HAS NO RESULTS TO READ. The site is open and
        // that is worth saying; pretending the search happened is not.
        guard searched.landed else {
            var arrivedAtTheSite = arrived
            arrivedAtTheSite.spoken =
                "I opened \(site), but I couldn't search it for \(wanted). \(arrived.spoken)"
            return arrivedAtTheSite
        }
        await engine.noteResultQuery(wanted)
        await engine.settleForResults(in: target)

        let read = await engine.readPage(in: target)
        guard read.ok else { return read }
        // The read's own rows — see the PIN in `WebSearchRecipe`.
        let results = await engine.snapshot().lastRoster ?? PageRoster(
            elements: read.elements, map: read.map ?? PageMapSummary(),
            pageFrame: read.shell?.pageFrame ?? .zero)
        let routed = await engine.arbitrate(
            wanted, verb: .openResult(query: wanted), in: results)
        guard let choice = routed.winner else {
            return BrowserOutcome(
                ok: true,
                spoken: "I searched \(site) for \(wanted). \(PageListing.tail(results))",
                shell: read.shell, elements: read.elements, map: read.map,
                receipts: searched.receipts, landed: searched.landed)
        }
        let pressed = await engine.pressOnPage(choice.label, in: target, deadline: deadline)
        guard pressed.landed else { return pressed }
        await engine.noteWatchRoad(.siteSearch)
        return await spoken(pressed, in: target, engine: engine)
    }

    /// The row that leads to a site's own front door, among the results.
    ///
    /// The shortest label wins: a site's own entry is named after the site,
    /// while an article ABOUT it carries a sentence.
    static func frontDoor(to site: String, among rows: [PageRow]) -> PageRow? {
        rows
            .filter { $0.site == site && $0.affordance == .press && $0.isNamed }
            .min { $0.label.count < $1.label.count }
    }

    /// The query with the site's own words taken out — "fireplace video on
    /// youtube" asked of YouTube is "fireplace video".
    static func withoutSite(_ site: String, in query: String) -> String {
        let siteWords = Set(RowFactsDerivation.folded(site).split(separator: " ").map(String.init))
        var kept: [String] = []
        for word in query.split(separator: " ").map(String.init) {
            let folded = RowFactsDerivation.folded(word)
            if siteWords.contains(folded) {
                // The preposition that carried the site goes with it.
                if kept.last.map({ RowFactsDerivation.folded($0) == "on" }) == true {
                    kept.removeLast()
                }
                continue
            }
            kept.append(word)
        }
        let remaining = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return remaining.isEmpty ? query : remaining
    }

    /// What arriving is worth saying — and what the player is doing, since
    /// somebody who asked to watch something wants to know it is playing.
    static func spoken(
        _ arrival: BrowserOutcome,
        in target: BrowserTarget, engine: BrowserEngine
    ) async -> BrowserOutcome {
        let described = await engine.describeMedia(in: target)
        guard described.ok, let media = described.media else { return arrival }
        var answer = arrival
        answer.spoken = "\(arrival.spoken) \(media.spoken)"
        answer.media = media
        return answer
    }
}

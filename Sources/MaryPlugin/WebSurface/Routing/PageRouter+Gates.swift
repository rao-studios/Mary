//
//  PageRouter+Gates.swift
//  MaryPlugin
//
//  WHAT: Which rows can serve a verb at all, and one sentence each for the rest.
//  IN:   PageRouter.arbitrate, before anything is scored
//  OUT:  PageRouteDisposition.ineligible with its reason
//  PIN:  THE GATE IS ABOUT THE ROW, NOT ABOUT THE GOAL. Whether a slider can be pressed
//        is true before anyone says anything; whether it is the slider they meant is the
//        ranking's question. Keeping them apart is what lets the trace say "isn't a
//        button" for one row and "something else answered better" for the next, instead
//        of one undifferentiated miss.
//        A REASON IS WRITTEN FOR SOMEBODY READING IT. It completes "…" after the row's
//        name, in the arbitrator's voice, and it is the only explanation this lane ever
//        gives for a row nobody could reach.
//        A CANDIDATE IS NOT AN OFFER. A row the reading NAMED but did not mark actionable
//        is admitted for pressing and revealing, because the classifier trades recall for
//        precision by design and a person naming something can see the screen — but it
//        carries that standing into the scoring, where it must clear a higher floor.
//

import Foundation
import MaryComputerUse

public extension PageRouter {

    /// Whether a row may serve this verb, and on what terms.
    enum Standing: Sendable, Equatable {
        /// The reading says this row does exactly what the verb needs.
        case offered
        /// Named by the page, not offered by the map. Admitted, and held to more.
        case candidate
        case ineligible(String)
        /// Real and reachable, just not of the sort this verb needs. Kept apart from
        /// `ineligible` because NAMING A REAL THING OF THE WRONG SORT IS A DIFFERENT
        /// MISTAKE FROM NAMING NOTHING, and it earns the sentence that says which.
        case mismatched(String)

        var admits: Bool {
            switch self {
            case .offered, .candidate: return true
            case .ineligible, .mismatched: return false
            }
        }

        var reason: String? {
            switch self {
            case .offered, .candidate: return nil
            case .ineligible(let reason), .mismatched(let reason): return reason
            }
        }
    }

    /// The gate. Common rules first, then the verb's own.
    static func standing(
        of row: PageRosterRow, verb: PageRouteVerb, in context: PageRouteContext
    ) -> Standing {
        // A NAME IS THE ONLY WAY IN. Every rung below reaches a row by what it is called,
        // so a row nothing named cannot be reached by anything and says so once.
        if row.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .ineligible("has no words to reach it with")
        }
        guard row.isNamed else {
            return .ineligible("has no name anyone wrote")
        }
        guard row.isEnabled else {
            return .ineligible("is unavailable")
        }

        switch verb {
        case .press:
            switch row.affordance {
            case .press, .fill: return .offered
            case .adjust: return .ineligible("is a slider, not a button")
            case .scroll: return .ineligible("is something to scroll, not to press")
            case .none: return .candidate
            }

        case .fill:
            if row.affordance == .fill { return .offered }
            // A FIELD THE MAP DID NOT CALL FILLABLE IS STILL A FIELD. The kind is derived
            // from the row's own role; the affordance is the reading's confidence about it.
            if row.kindWord == PageElementKind.field.spokenWord { return .offered }
            // AND WHERE NOTHING ON THE PAGE READS AS A FIELD AT ALL, a named row is a
            // candidate rather than a refusal.
            //
            // PIN: MEASURED ON A LIVE SITE whose search box the classifier called static
            // text — the row said "Search or ask a question", which is what anybody
            // looking at the page would call the search box, and the lane could not type
            // into it. This is the pool fallback the old ladder had (`fillable.isEmpty ?
            // actionable`), kept, with the difference that a candidate must now clear the
            // higher floor rather than winning on the naming ladder alone. Where the page
            // DOES offer fields, naming something else is naming the wrong sort of thing
            // and still earns that sentence.
            return context.hasFillableRow
                ? .mismatched("isn't something I can type into")
                : .candidate

        case .adjust:
            return row.affordance == .adjust ? .offered : .mismatched("isn't a slider")

        case .reveal:
            // Bringing something into view changes nothing, so anything named will do.
            return .offered

        case .openResult(let query):
            return resultStanding(of: row, query: query, in: context)
        }
    }

    /// What can be a search result, which is a narrower question than what can be pressed.
    ///
    /// PIN: EVERY ONE OF THESE WAS MEASURED ON A LIVE RESULTS PAGE. The address a card
    /// prints above its link, the site's own "News · Videos · Web" strip, the search box
    /// holding the query back, the "Searches related to …" band at the foot — each is
    /// long, named, and pressable, and each was opened by some earlier ranking that had
    /// no way to tell it from an answer.
    private static func resultStanding(
        of row: PageRosterRow, query: String, in context: PageRouteContext
    ) -> Standing {
        // ORDERED BY WHAT IS MOST WORTH SAYING. Several of these are true of the same
        // row — a site's "Sign in" is short AND a call to action — and the sentence a
        // person reads should name the reason that explains the row, not the cheapest
        // test that happened to fire first.
        if PageElementKindDerivation.isCallToAction(row.label) {
            return .ineligible("is a call to action")
        }
        if row.label.lowercased().hasPrefix("http") {
            return .ineligible("is an address, not a title")
        }
        if isEcho(row.label, of: query) {
            return .ineligible("is the query echoed back")
        }
        if isSeparatedStrip(row.label) {
            return .ineligible("is a strip of page furniture")
        }
        if row.label.count < minimumResultLabel {
            return .ineligible("is too short to be a result")
        }
        let groups = context.groupKinds(forOrdinal: row.ordinal)
        let isFurnitureGroup = groups.contains("toolbar") || groups.contains("form")
        // A ROW THE MAP ITSELF OFFERS, sitting in a toolbar or a form, is chrome, full
        // stop — a real nav button or a login field, never a search result, however it
        // is named. This half stays unconditional.
        if row.affordance != .none, isFurnitureGroup {
            return .ineligible("is page furniture")
        }
        guard row.affordance == .none else { return .offered }
        // A ROW THE MAP NAMED AND DID NOT OFFER is a CANDIDATE where the page's own
        // structure vouches for it — a result group, or a title geometry promoted.
        if groups.contains(where: resultGroupKinds.contains) { return .candidate }
        if row.affordanceSource == .grouping { return .candidate }
        // NEITHER GROUPED AS RESULTS NOR PROMOTED — including "toolbar"/"form", which
        // for an UNOFFERED row is VisionAX's own grouping guess, not a fact about the
        // row. Nothing vouches for it as a GUESS — but naming it exactly is a different
        // question from guessing among it.
        //
        // PIN: THE NO-PICK GUESS IS UNCHANGED. Measured on a live results page: 80 rows
        // read, none marked actionable, no result group, and what the reading actually
        // held was a region picker, thirteen related-search suggestions, and the real
        // titles BROKEN ACROSS ROWS. Every ranking tried on that pool picked a different
        // piece of furniture with nobody having named anything — a pool nothing vouches
        // for is not a weaker pool to guess among, it is a different page from the one
        // the person is looking at. That refusal stands: with no pick, this row is
        // ineligible, exactly as before.
        //
        // BUT A NAMED ROW IS A DIFFERENT CLAIM. Measured live, on two different pages:
        // a "related searches" panel grouped as a card while a real, correctly split
        // title sat ungrouped beside it; and, on the video site's own results, a real
        // title grouped as "toolbar" — the same mis-grouping this file already treats
        // as unreliable, now caught by the very check meant to exclude nav chrome.
        // `.press`/`.fill`/`.adjust` all reach an ungrouped row on an exact name — "a
        // person naming something is evidence the map does not have" is not a rule
        // `.openResult` gets to suspend just because it also has a floor for guessing.
        // So a real pick admits the row as a candidate too; `structureScore` still
        // marks it down, which is what stops a WEAK match from beating a properly
        // grouped result, while an EXACT name still wins outright.
        guard context.hasPick else {
            return .ineligible(isFurnitureGroup
                ? "is page furniture" : "was named but sits in no result group")
        }
        return .candidate
    }

    /// A row shorter than this is a breadcrumb or a "next", not something anybody
    /// searched for.
    static let minimumResultLabel = 12

    /// Group kinds a page uses for its answers.
    static let resultGroupKinds: Set<String> = ["row", "card", "list"]

    /// SEVERAL SHORT NAMES JOINED BY SEPARATORS ARE A NAVIGATION STRIP, not one answer.
    ///
    /// PIN: MEASURED, AND IT IS A SHAPE RATHER THAN A LIST OF SITES. A results page draws
    /// its own tabs as one row — "News + AI Chat & Images · Videos · Web" — which is long,
    /// named, pressable and first, so every ranking that reached past the map opened it.
    /// What gives it away is that it is a LIST: three or more segments whose typical
    /// length is a word or two. A real title carrying a separator has two segments and a
    /// long one ("Boiler Room London · 1:02:33"), so the same test leaves it alone.
    static func isSeparatedStrip(_ label: String) -> Bool {
        let segments = label
            .components(separatedBy: CharacterSet(charactersIn: "·•|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count >= stripSegmentMinimum else { return false }
        let lengths = segments.map(\.count).sorted()
        return lengths[lengths.count / 2] < minimumResultLabel
    }

    /// How many segments before a row reads as a list of links rather than a title.
    static let stripSegmentMinimum = 3

    /// Is this row the query, said back?
    ///
    /// PIN: A RESULTS PAGE SHOWS YOU WHAT YOU ASKED FOR — in its own search box, and again
    /// under "Searches related to …" at the foot. Both are pressable, well named and the
    /// right length, and both carry every word of the query, so meaning cannot separate
    /// them from an answer: they say the query and nothing more. What is LEFT after the
    /// query is removed is the test, and the allowance is small — a recognized magnifier,
    /// a trailing mark, or the few words a page wraps around its own echo.
    static func isEcho(_ label: String, of query: String) -> Bool {
        let folded = fold(label)
        let asked = fold(query)
        guard !asked.isEmpty else { return false }
        let squashedLabel = folded.replacingOccurrences(of: " ", with: "")
        let squashedQuery = asked.replacingOccurrences(of: " ", with: "")
        guard !squashedQuery.isEmpty else { return false }
        if squashedLabel.contains(squashedQuery) {
            return squashedLabel.count - squashedQuery.count < echoSlack
        }
        // A PAGE TRUNCATES ITS OWN ECHO. "Searches related to a fred again video on"
        // drops the last word of what was typed and is still the page talking about the
        // query rather than answering it.
        let words = asked.split(separator: " ").map(String.init)
        guard words.count > 1 else { return false }
        let shortened = words.dropLast().joined().lowercased()
        guard shortened.count >= truncatedEchoMinimum,
              squashedLabel.contains(shortened)
        else { return false }
        return squashedLabel.count - shortened.count < truncatedEchoSlack
    }

    /// How much more than the WHOLE query a row may say and still be repeating it.
    /// MEASURED: the search box adds a recognized magnifier, or a trailing mark. A real
    /// title contains the query and then says something — "Alpine touring boots REVIEWED".
    static let echoSlack = 3

    /// And how much more than a TRUNCATED query, where the page wrapped its own words
    /// around the echo. MEASURED: "Searches related to a fred again video on" — seventeen
    /// characters of the page talking about the search rather than answering it.
    static let truncatedEchoSlack = 24

    /// Below this a truncated query is too short to be evidence of anything.
    static let truncatedEchoMinimum = 12

    /// Letters and digits, single-spaced. The one folding this lane compares with.
    static func fold(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
}

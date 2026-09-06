//
//  PageRouter+Gates.swift
//  MaryPlugin
//
//  WHAT: Which rows can serve a verb at all, and one sentence each for the rest.
//  IN:   the arbitration, before anything is scored
//  OUT:  ArbitrationStanding, with its reason
//  PIN:  THE GATE IS ABOUT THE ROW, NOT ABOUT THE GOAL. Whether a slider can be
//        pressed is true before anyone says anything; whether it is the slider
//        they meant is the ranking's question. Keeping them apart is what lets
//        the trace say "isn't a button" for one row and "something else answered
//        better" for the next, instead of one undifferentiated miss.
//        AND IT READS FACTS RATHER THAN DERIVING THEM. This was seven ordered
//        text heuristics run at ranking time — is it a call to action, a bare
//        address, a strip of the site's own tabs — each a property of the ROW
//        that is true whether or not anyone is routing. They live at the seal
//        now (`RowFacts`), decided once; what is left here is the verb's own
//        question, which is the only thing a gate should be.
//        A REASON IS WRITTEN FOR SOMEBODY READING IT. It completes "…" after the
//        row's name, in the arbitrator's voice, and it is the only explanation
//        this lane ever gives for a row nobody could reach.
//        A CANDIDATE IS NOT AN OFFER. A row the reading NAMED but did not mark
//        actionable is admitted for pressing and revealing, because the
//        classifier trades recall for precision by design and a person naming
//        something can see the screen — but it carries that standing into the
//        scoring, where it must clear a higher floor.
//

import Foundation
import MaryAmbient
import MaryComputerUse

public extension PageRouter {

    /// A candidate the reading named but did not offer.
    static let candidate = ArbitrationStanding.candidate

    /// Whether a row may serve this verb, and on what terms.
    static func standing(
        of row: PageRow, verb: PageRouteVerb, in domain: PageRouteDomain
    ) -> ArbitrationStanding {
        // A NAME IS THE ONLY WAY IN. Every rung below reaches a row by what it is
        // called, so a row nothing named cannot be reached by anything and says
        // so once.
        if row.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .ineligible("has no words to reach it with")
        }
        guard row.isNamed else {
            return .ineligible("has no name anyone wrote")
        }
        guard row.isEnabled else {
            return .ineligible("is unavailable")
        }
        // WHERE THEY SAID, BEFORE WHAT THEY SAID. See `regionNamedInGoal`.
        if let wanted = domain.regionNamedInGoal {
            guard let wanted else {
                return .mismatched("is on a page with no such part to it")
            }
            guard row.region == wanted else {
                return .mismatched("isn't \(wanted.spokenPlace)")
            }
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
            // A FIELD THE MAP DID NOT CALL FILLABLE IS STILL A FIELD. The kind is
            // derived from the row's own role; the affordance is the reading's
            // confidence about it.
            if row.kind == .field { return .offered }
            // AND WHERE NOTHING ON THE PAGE READS AS A FIELD AT ALL, a named row
            // is a candidate rather than a refusal.
            //
            // PIN: MEASURED ON A LIVE SITE whose search box the classifier called
            // static text — the row said "Search or ask a question", which is what
            // anybody looking at the page would call the search box, and the lane
            // could not type into it. This is the pool fallback the old ladder had
            // (`fillable.isEmpty ? actionable`), kept, with the difference that a
            // candidate must now clear the higher floor rather than winning on the
            // naming ladder alone. Where the page DOES offer fields, naming
            // something else is naming the wrong sort of thing and still earns
            // that sentence.
            return domain.hasFillableRow
                ? .mismatched("isn't something I can type into")
                : .candidate

        case .adjust:
            return row.affordance == .adjust ? .offered : .mismatched("isn't a slider")

        case .reveal:
            // Bringing something into view changes nothing, so anything named will do.
            return .offered

        case .openResult:
            return resultStanding(of: row, in: domain)
        }
    }

    /// What can be a search result, which is a narrower question than what can be
    /// pressed.
    ///
    /// PIN: EVERY ONE OF THESE WAS MEASURED ON A LIVE RESULTS PAGE. The address a
    /// card prints above its link, the site's own "News · Videos · Web" strip,
    /// the search box holding the query back, the "Searches related to …" band at
    /// the foot — each is long, named, and pressable, and each was opened by some
    /// earlier ranking that had no way to tell it from an answer. Each is now a
    /// FACT the reading carries, so this reads them rather than re-deriving them.
    /// ORDERED BY WHAT IS MOST WORTH SAYING. Several are true of the same row — a
    /// site's "Sign in" is short AND a call to action — and the sentence a person
    /// reads should name the reason that explains the row, not the cheapest test
    /// that happened to fire first.
    private static func resultStanding(
        of row: PageRow, in domain: PageRouteDomain
    ) -> ArbitrationStanding {
        if row.facts.contains(.callToAction) {
            return .ineligible("is a call to action")
        }
        if row.facts.contains(.bareAddress) {
            return .ineligible("is an address, not a title")
        }
        if row.facts.contains(.echoOfQuery) {
            return .ineligible("is the query echoed back")
        }
        if row.facts.contains(.separatedStrip) {
            return .ineligible("is a strip of page furniture")
        }
        if row.facts.contains(.tooShortForTitle) {
            return .ineligible("is too short to be a result")
        }
        let isFurnitureGroup = !row.facts.isDisjoint(with: .furnitureGroups)
        // A ROW THE MAP ITSELF OFFERS, sitting in a toolbar or a form, is chrome,
        // full stop — a real nav button or a login field, never a search result,
        // however it is named. This half stays unconditional.
        if row.affordance != .none, isFurnitureGroup {
            return .ineligible("is page furniture")
        }
        guard row.affordance == .none else { return .offered }
        // A ROW THE MAP NAMED AND DID NOT OFFER is a CANDIDATE where the page's
        // own structure vouches for it — a result group, or a title geometry
        // promoted.
        if row.facts.contains(.inResultGroup) { return .candidate }
        if row.affordanceSource == .grouping { return .candidate }
        // NEITHER GROUPED AS RESULTS NOR PROMOTED — including toolbar and form,
        // which for an UNOFFERED row is VisionAX's own grouping guess, not a fact
        // about the row. Nothing vouches for it as a GUESS — but naming it exactly
        // is a different question from guessing among it.
        //
        // PIN: THE NO-PICK GUESS IS UNCHANGED. Measured on a live results page: 80
        // rows read, none marked actionable, no result group, and what the reading
        // actually held was a region picker, thirteen related-search suggestions,
        // and the real titles BROKEN ACROSS ROWS. Every ranking tried on that pool
        // picked a different piece of furniture with nobody having named anything
        // — a pool nothing vouches for is not a weaker pool to guess among, it is
        // a different page from the one the person is looking at. That refusal
        // stands: with no pick, this row is ineligible, exactly as before.
        //
        // BUT A NAMED ROW IS A DIFFERENT CLAIM. Measured live, on two different
        // pages: a "related searches" panel grouped as a card while a real,
        // correctly split title sat ungrouped beside it; and, on the video site's
        // own results, a real title grouped as "toolbar" — the same mis-grouping
        // this file already treats as unreliable, now caught by the very check
        // meant to exclude nav chrome. `.press`/`.fill`/`.adjust` all reach an
        // ungrouped row on an exact name — "a person naming something is evidence
        // the map does not have" is not a rule `.openResult` gets to suspend just
        // because it also has a floor for guessing. So a real pick admits the row
        // as a candidate too; `structureScore` still marks it down, which is what
        // stops a WEAK match from beating a properly grouped result, while an
        // EXACT name still wins outright.
        guard domain.hasPick else {
            return .ineligible(isFurnitureGroup
                ? "is page furniture" : "was named but sits in no result group")
        }
        return .candidate
    }

    /// A row shorter than this is a breadcrumb or a "next", not something anybody
    /// searched for. THE SEAL'S NUMBER, named here so a reader of the gate can see
    /// what `tooShortForTitle` meant.
    static var minimumResultLabel: Int { RowFactsDerivation.minimumResultLabel }
}

//
//  RowFacts.swift
//  MaryComputerUse
//
//  WHAT: What is true of a row, decided once, from the reading alone.
//  IN:   VisionPageReader, after the map crosses the seal
//  OUT:  the page router's gates; anything ranking rows
//  PIN:  A FACT ABOUT THE ROW, NOT A STEP IN A LADDER. These were seven ordered
//        `if`s inside the router's result gate, each deriving a property of the
//        row from its label text at ranking time — is it a call to action, is it
//        a bare address, is it a strip of the site's own tabs. Every one is a
//        thing that is TRUE OF THE ROW whether or not anyone is routing, and
//        deciding them in the gate meant three things: the gate could not be read
//        without reading seven text heuristics, the same question was asked again
//        for every goal, and no other consumer could see the answers at all.
//        DERIVED FROM THE READING, NEVER FROM THE GOAL. The one fact that depends
//        on what was asked — is this row the query said back — is added later, by
//        the engine, when a query exists. Everything here is a function of the
//        page.
//        THE RULES ARE THE MEASURED ONES, MOVED WHOLE. Every threshold below came
//        off a live page; none is re-derived here.
//

import CoreGraphics
import Foundation

/// What is true of one row.
public struct RowFacts: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// "Sign in", "Subscribe" — the page asking, not the page answering.
    public static let callToAction = RowFacts(rawValue: 1 << 0)
    /// The label is an address a card printed above its link, not a title.
    public static let bareAddress = RowFacts(rawValue: 1 << 1)
    /// Several short names joined by separators — a site's own tab strip drawn
    /// as one row: long, named, pressable, and never an answer.
    public static let separatedStrip = RowFacts(rawValue: 1 << 2)
    /// Shorter than anything anybody searched for — a breadcrumb, a "next".
    public static let tooShortForTitle = RowFacts(rawValue: 1 << 3)
    /// The page said it was paid for.
    public static let promoted = RowFacts(rawValue: 1 << 4)
    /// It sits in a band of mostly-short labels — page furniture by shape.
    public static let inFurnitureBand = RowFacts(rawValue: 1 << 5)
    /// A dialog is up and this row is not in it.
    public static let behindOverlay = RowFacts(rawValue: 1 << 6)
    /// A dialog is up and this row IS in it.
    public static let inOverlay = RowFacts(rawValue: 1 << 7)
    /// It sits in a group the page laid its answers out in.
    public static let inResultGroup = RowFacts(rawValue: 1 << 8)
    /// It sits in the page's own chrome.
    public static let inToolbar = RowFacts(rawValue: 1 << 9)
    /// It sits among fields and their labels.
    public static let inForm = RowFacts(rawValue: 1 << 10)
    /// Another row on this same read carries the identical name.
    public static let duplicateLabel = RowFacts(rawValue: 1 << 11)
    /// THE ONE QUERY-DEPENDENT FACT, added by the engine rather than the seal:
    /// the row is the search query said back — the box it was typed into, or the
    /// "searches related to …" band at the foot. Both are pressable, well named
    /// and the right length, so nothing but the query can tell them from a result.
    public static let echoOfQuery = RowFacts(rawValue: 1 << 12)
    /// NOT DRAWN, THOUGH THE TREE PUBLISHES IT — a skip link, an off-canvas
    /// menu. Reachable by name; never what somebody means by "the first one".
    ///
    /// PIN: NOTHING SETS THIS, AND TWO MEASUREMENTS SAY WHY — both of them
    /// refutations of an idea that looked right.
    ///
    /// FIRST: that a skip link is positioned OFF the page and clipped back in,
    /// which would make it geometry the walk can see. It is not. On a search
    /// page "Skip to main content" is drawn at 110x44 eleven points INSIDE the
    /// page's own left edge; it is hidden by means accessibility does not report
    /// at all — opacity, a clip path, a transform. The frame is honest and the
    /// row is invisible.
    ///
    /// SECOND: that the pixel lane could witness it, since it is the only lane
    /// that sees what is DRAWN. Measured across three sites, counting walked
    /// rows that no seen row overlaps: 4 of 48, 2 of 56, 0 of 60 — and the skip
    /// link is in none of them, while "Clear", "Main menu" and "About this
    /// result" are. The pixel lane misses real controls and does not miss this
    /// one, so using it as evidence of invisibility would hide three visible
    /// things to hide one invisible one.
    ///
    /// The fact and the gate that reads it are kept because the RULE is right —
    /// a row nobody can see is not what "the first one" means. What is missing
    /// is evidence neither lane publishes today.
    public static let notDrawn = RowFacts(rawValue: 1 << 13)

    /// The page's own furniture, however it is named.
    public static let furnitureGroups: RowFacts = [.inToolbar, .inForm]
}

public enum RowFactsDerivation {

    /// A row shorter than this is a breadcrumb or a "next", not something
    /// anybody searched for.
    public static let minimumResultLabel = 12

    /// How many segments before a row reads as a list of links rather than a
    /// title. MEASURED: a results page draws its own tabs as one row — "News +
    /// AI Chat & Images · Videos · Web" — which is long, named, pressable and
    /// first, so every ranking that reached past the map opened it. What gives
    /// it away is that it is a LIST: three or more segments whose typical length
    /// is a word or two. A real title carrying a separator has two segments and a
    /// long one ("Boiler Room London · 1:02:33"), so the same test leaves it alone.
    public static let stripSegmentMinimum = 3

    /// A BAND OF SHORT LABELS IS A STRIP, NOT A LIST OF ANSWERS. Measured: a
    /// site's own "News · Videos · Web" row reads as a band of three short
    /// labels and was opened by page order.
    public static let furnitureBandMinimum = 3

    /// What a page calls a row it was paid to show.
    public static let promotionHints: Set<String> = [
        "sponsored", "ad", "ads", "promoted", "advertisement",
    ]

    /// Every row's facts, from the reading alone.
    ///
    /// Takes the rows it is about to annotate, because three of the facts are
    /// about a row's PLACE among the others — which band it sits in, whether a
    /// dialog covers it, whether another row says the same thing.
    public static func derive(rows: [PageRow], groups: [PageGroup]) -> [PageRow] {
        let overlayOrdinals = Set(
            groups.filter { $0.kind == .overlay }.flatMap(\.memberOrdinals))
        let hasOverlay = !overlayOrdinals.isEmpty

        // A band whose labels are mostly too short to be answers is furniture.
        var furnitureOrdinals: Set<Int> = []
        let labelByOrdinal = Dictionary(
            rows.map { ($0.ordinal, $0.label) }, uniquingKeysWith: { first, _ in first })
        for group in groups where group.kind == .band
            && group.memberOrdinals.count >= furnitureBandMinimum {
            let labels = group.memberOrdinals.compactMap { labelByOrdinal[$0] }
            let short = labels.filter { $0.count < minimumResultLabel }.count
            if short * 2 > labels.count { furnitureOrdinals.formUnion(group.memberOrdinals) }
        }

        // A LABEL TWO ROWS CLAIM IS A LABEL NEITHER OWNS. Measured as pervasive
        // rather than a one-page fluke: 15 of 80 rows and 6 of 142 rows shared an
        // identical label with another row on the same read, because an outer
        // link and the text inside it are both emitted.
        var counts: [String: Int] = [:]
        for row in rows {
            let folded = folded(row.label)
            guard !folded.isEmpty else { continue }
            counts[folded, default: 0] += 1
        }

        return rows.map { row in
            var row = row
            var facts = row.facts
            if PageElementKindDerivation.isCallToAction(row.label) {
                facts.insert(.callToAction)
            }
            if row.label.lowercased().hasPrefix("http") { facts.insert(.bareAddress) }
            if isSeparatedStrip(row.label) { facts.insert(.separatedStrip) }
            if row.label.count < minimumResultLabel { facts.insert(.tooShortForTitle) }
            if row.hints.contains(where: { promotionHints.contains($0.lowercased()) }) {
                facts.insert(.promoted)
            }
            if furnitureOrdinals.contains(row.ordinal) { facts.insert(.inFurnitureBand) }
            if hasOverlay {
                facts.insert(
                    overlayOrdinals.contains(row.ordinal) ? .inOverlay : .behindOverlay)
            }
            switch row.group?.kind {
            case .some(let kind) where SeenGroupKind.results.contains(kind):
                facts.insert(.inResultGroup)
            case .toolbar: facts.insert(.inToolbar)
            case .form: facts.insert(.inForm)
            default: break
            }
            if (counts[folded(row.label)] ?? 0) > 1 { facts.insert(.duplicateLabel) }
            row.facts = facts
            return row
        }
    }

    /// SEVERAL SHORT NAMES JOINED BY SEPARATORS ARE A NAVIGATION STRIP.
    public static func isSeparatedStrip(_ label: String) -> Bool {
        let segments = label
            .components(separatedBy: CharacterSet(charactersIn: "·•|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count >= stripSegmentMinimum else { return false }
        let lengths = segments.map(\.count).sorted()
        return lengths[lengths.count / 2] < minimumResultLabel
    }

    /// Is this row the query, said back?
    ///
    /// PIN: A RESULTS PAGE SHOWS YOU WHAT YOU ASKED FOR — in its own search box,
    /// and again under "Searches related to …" at the foot. Both are pressable,
    /// well named and the right length, and both carry every word of the query,
    /// so meaning cannot separate them from an answer: they say the query and
    /// nothing more. What is LEFT after the query is removed is the test, and the
    /// allowance is small — a recognized magnifier, a trailing mark, or the few
    /// words a page wraps around its own echo.
    public static func isEcho(_ label: String, of query: String) -> Bool {
        let foldedLabel = folded(label)
        let asked = folded(query)
        guard !asked.isEmpty else { return false }
        let squashedLabel = foldedLabel.replacingOccurrences(of: " ", with: "")
        let squashedQuery = asked.replacingOccurrences(of: " ", with: "")
        guard !squashedQuery.isEmpty else { return false }
        if squashedLabel.contains(squashedQuery) {
            return squashedLabel.count - squashedQuery.count < echoSlack
        }
        // A PAGE TRUNCATES ITS OWN ECHO. "Searches related to a fred again video
        // on" drops the last word of what was typed and is still the page talking
        // about the query rather than answering it.
        let words = asked.split(separator: " ").map(String.init)
        guard words.count > 1 else { return false }
        let shortened = words.dropLast().joined().lowercased()
        guard shortened.count >= truncatedEchoMinimum,
              squashedLabel.contains(shortened)
        else { return false }
        return squashedLabel.count - shortened.count < truncatedEchoSlack
    }

    /// How much more than the WHOLE query a row may say and still be repeating
    /// it. MEASURED: the search box adds a recognized magnifier, or a trailing
    /// mark. A real title contains the query and then says something —
    /// "Alpine touring boots REVIEWED".
    public static let echoSlack = 3

    /// And how much more than a TRUNCATED query, where the page wrapped its own
    /// words around the echo. MEASURED: "Searches related to a fred again video
    /// on" — seventeen characters of the page talking about the search rather
    /// than answering it.
    public static let truncatedEchoSlack = 24

    /// Below this a truncated query is too short to be evidence of anything.
    public static let truncatedEchoMinimum = 12

    /// Letters and digits, single-spaced. The one folding this lane compares with.
    public static func folded(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
}

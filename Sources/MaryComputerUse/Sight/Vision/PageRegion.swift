//
//  PageRegion.swift
//  MaryComputerUse
//
//  WHAT: Where on the page a row sits — the words a person points with.
//  IN:   the merged rows and the page frame, at the seal
//  OUT:  SpokenReference's second filter; the landscape a listing speaks
//  PIN:  A PAGE HAS A SHAPE AND NOBODY COULD SAY IT. Every other way of naming a
//        row was a WORD — its label, its kind, its position in reading order —
//        and a person looking at a page does not read it in reading order. They
//        say "the search box at the top", "the third link in the sidebar", "the
//        button at the bottom of the article". None of those could be asked
//        before this file, and the fallback was an ordinal over the whole page,
//        which counts a site's own navigation as the first nine things on it.
//
//        GEOMETRY, NEVER MARKUP. There is no `<header>` here and no landmark
//        role: a region is where a row IS, measured against the rendered page,
//        so it means the same thing on a site that marks its structure up and on
//        one that draws it. THE COLUMN IS FOUND, NOT ASSUMED — the web's
//        three-column page puts navigation left, content middle and asides
//        right, but the boundaries are a site's choice, so they are measured from
//        where the page's own rows actually are.
//
//        THE SAME SHAPE AS `PageElementKind.admittingWords` AND
//        `SpokenOrdinal.words`, deliberately: a small closed vocabulary of
//        ENGLISH, holding no site's name, no label and no scenario. That is the
//        distinction the browsing doctrine draws, and this file sits on the
//        legitimate side of it for the same reason "third" does.
//

import CoreGraphics
import Foundation

/// Where on the page a row sits.
public enum PageRegion: String, Sendable, Equatable, Codable, CaseIterable {
    /// The band across the top: a site's masthead, its search, its account links.
    case header
    /// A column down the left of the content.
    case leading
    /// The page's own body — where what it is about actually is.
    case main
    /// A column down the right: asides, related things, a knowledge panel.
    case trailing
    /// The band across the bottom.
    case footer
    /// A dialog covering the page. Not geometry — see `RowFacts.inOverlay`.
    case overlay

    /// Words that admit this region when the user says them.
    ///
    /// PIN: KEPT SMALL AND GENERIC, the same rule `admittingWords` already
    /// states. "The nav" is English; "the Wikipedia sidebar" would be a site.
    public var admittingWords: [String] {
        switch self {
        case .header:
            return ["top", "header", "masthead", "nav", "navigation", "menu bar", "top bar"]
        case .leading:
            return ["left", "left side", "sidebar", "left sidebar", "left column", "left hand side"]
        case .main:
            return ["article", "main", "body", "content", "middle", "centre", "center",
                    "main column", "page itself"]
        case .trailing:
            return ["right", "right side", "right sidebar", "right column",
                    "right hand side", "panel", "aside"]
        case .footer:
            // "BOTTOM" ALONE IS ALREADY A POSITION. `SpokenOrdinal.lastWords`
            // reads it as "the last one", and a word that means both a place and
            // a position makes "the bottom link" mean two things at once. The
            // longer phrases are unambiguous, and they still compose correctly
            // with the ordinal: "the button at the bottom of the page" filters to
            // the footer and then takes the last of them, which is what it says.
            return ["footer", "foot of the page", "bottom of the page",
                    "bottom of the screen"]
        case .overlay:
            return ["dialog", "popup", "pop up", "banner", "modal", "overlay", "notice"]
        }
    }

    /// How a listing names it. `main` is deliberately not spoken as "main" —
    /// nobody says "in the main"; they say "the page itself".
    public var spokenPlace: String {
        switch self {
        case .header:   return "across the top"
        case .leading:  return "down the left"
        case .main:     return "in the page itself"
        case .trailing: return "down the right"
        case .footer:   return "along the bottom"
        case .overlay:  return "in the dialog that is up"
        }
    }

    /// THE REGION A PHRASE NAMES, among the regions the page actually has.
    ///
    /// PIN: AMONG THE ONES PRESENT, exactly as `offeredKind` matches among the
    /// kinds present. Naming a region a page has none of must be a miss, not a
    /// filter that empties the pool and then falls back to everything — which is
    /// how "the third link in the sidebar" on a page with no sidebar would come
    /// to open the third link in the article.
    /// LONGEST WORD FIRST, so "left sidebar" beats "left" and "top bar" beats
    /// "top".
    public static func named(
        in phrase: String, among present: Set<PageRegion>
    ) -> PageRegion? {
        let lowered = " \(phrase.lowercased()) "
        return present
            .flatMap { region in region.admittingWords.map { (region, $0) } }
            .filter { lowered.contains(" \($0.1) ") || lowered.contains(" \($0.1)s ") }
            .sorted { $0.1.count > $1.1.count }
            .first?.0
    }

    /// Every word any region answers to, for a caller stripping them out of a
    /// name before it looks for one.
    public static var allWords: [String] {
        allCases.flatMap(\.admittingWords)
    }

    /// THE GOAL WITH THE PLACE TAKEN OUT OF IT.
    ///
    /// PIN: A PLACE IS SPENT ONCE. Naming where something is narrows the page —
    /// the gate has already used it — and leaving the words in the sentence
    /// spends them a second time against the row's own meaning, where they mean
    /// nothing: MEASURED, "the search box at the top" scored 431 against the
    /// row that IS the search box while "the search box" scored 624, purely for
    /// the three words that had already done their work. Same argument as
    /// `RoutingQuery.bareRequest` one layer up, and the same shape of fix.
    public func removed(from goal: String) -> String {
        var value = " \(goal) "
        for word in (admittingWords + ["in the", "on the", "at the", "down the",
                                       "across the", "along the", "inside the"])
            .sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(
                of: " \(word) ", with: " ", options: [.caseInsensitive])
        }
        return value
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

public enum PageRegionDerivation {

    /// The top band, as a fraction of the rendered page's height. MEASURED
    /// across Wikipedia, a search page and a feed: a site's masthead and its
    /// account links sit inside the first tenth; the first content row of all
    /// three sits below it.
    public static let headerBand = 0.10
    /// The bottom band, same measurement from the other end.
    public static let footerBand = 0.90
    /// How many vertical slices the width is measured in. Ten is one per tenth
    /// of the page — finer than any site's column boundary and coarse enough
    /// that a single wide row cannot invent a column.
    public static let slices = 10
    /// How much of the page's row-area the main column must hold.
    ///
    /// PIN: THE NARROWEST RUN THAT HOLDS THE PAGE, NOT THE SLICES THAT BEAT THE
    /// BUSIEST ONE. MEASURED on a search page, where the first rule failed: one
    /// slice of small dense rows set a peak the neighbouring slices could not
    /// reach, so the column was carved down to it and the page's own results —
    /// sitting just left of that slice — were reported as a sidebar. Asking
    /// instead for the smallest span that carries most of the page gives a
    /// column that grows to fit the content rather than shrinking to fit a peak.
    public static let mainColumnShare = 0.6
    /// A row overhanging the main column by less than this share of its own
    /// width is still in it — a heading that sticks out is not a sidebar.
    public static let columnTolerance = 0.15

    /// Every row's region, from the reading and the page's own frame.
    ///
    /// PIN: TWO PASSES AND NO GUESSING. The first finds the page's main column
    /// by asking where its rows actually are; the second places each row against
    /// it. A page with one column comes out all `main`, which is the right answer
    /// and not a degenerate one.
    public static func assign(rows: [PageRow], pageFrame: CGRect) -> [PageRow] {
        guard pageFrame.width > 0, pageFrame.height > 0, !rows.isEmpty else { return rows }

        func band(_ row: PageRow) -> PageRegion? {
            let y = (row.frame.midY - pageFrame.minY) / pageFrame.height
            if y < headerBand { return .header }
            if y > footerBand { return .footer }
            return nil
        }

        // WHERE THE PAGE'S WORDS ARE. Only the middle rows vote: a masthead
        // spans the full width and would flatten every slice into the column.
        var weight = [Double](repeating: 0, count: slices)
        for row in rows where band(row) == nil {
            let area = Double(row.frame.width * row.frame.height)
            guard area > 0 else { continue }
            let from = slice(row.frame.minX, in: pageFrame)
            let to = slice(row.frame.maxX, in: pageFrame)
            for index in from...to { weight[index] += area / Double(to - from + 1) }
        }
        let column = mainColumn(weight: weight, pageFrame: pageFrame)

        return rows.map { row in
            var row = row
            if row.facts.contains(.inOverlay) {
                row.region = .overlay
                return row
            }
            if let band = band(row) {
                row.region = band
                return row
            }
            guard let column else {
                row.region = .main
                return row
            }
            let slack = Double(row.frame.width) * columnTolerance
            if Double(row.frame.maxX) - slack <= column.lowerBound {
                row.region = .leading
            } else if Double(row.frame.minX) + slack >= column.upperBound {
                row.region = .trailing
            } else {
                row.region = .main
            }
            return row
        }
    }

    /// The narrowest contiguous run of slices that carries the page. Nil when no
    /// run narrower than the whole width does — a one-column page, where every
    /// middle row is `main` by definition and saying otherwise would invent a
    /// sidebar out of a margin.
    static func mainColumn(weight: [Double], pageFrame: CGRect) -> ClosedRange<Double>? {
        let total = weight.reduce(0, +)
        guard total > 0 else { return nil }
        let wanted = total * mainColumnShare
        var best: ClosedRange<Int>?
        for from in weight.indices {
            var carried = 0.0
            for to in from..<weight.count {
                carried += weight[to]
                guard carried >= wanted else { continue }
                let run = from...to
                if best == nil || run.count < best!.count { best = run }
                break
            }
        }
        guard let best, best.count < weight.count else { return nil }
        let width = Double(pageFrame.width) / Double(weight.count)
        let from = Double(pageFrame.minX) + Double(best.lowerBound) * width
        let to = Double(pageFrame.minX) + Double(best.upperBound + 1) * width
        return from...to
    }

    private static func slice(_ x: CGFloat, in pageFrame: CGRect) -> Int {
        let fraction = (x - pageFrame.minX) / pageFrame.width
        return min(slices - 1, max(0, Int(fraction * CGFloat(slices))))
    }
}

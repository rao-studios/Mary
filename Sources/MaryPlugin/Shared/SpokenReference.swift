//
//  SpokenReference.swift
//  MaryPlugin
//
//  WHAT: Phrase ladder shared by page and snapshot lanes.
//  OUT:  PageElementResolver | ScreenElementResolver

import Foundation
import MaryComputerUse

/// What the ladder needs from an element: something spoken, and — if it belongs to a
/// countable category — which one.
public protocol SpokenReferable {
    var spokenLabel: String { get }
    var spokenKind: PageElementKind? { get }
    /// WHERE ON THE PAGE IT SITS. Nil for a lane that has no page to sit on —
    /// a native window's roster — and the filter is skipped whenever no element
    /// in the pool has one, so a region word in a phrase about a window is
    /// treated as part of the name, exactly as it was before regions existed.
    var spokenRegion: PageRegion? { get }
}

extension SpokenReferable {
    public var spokenRegion: PageRegion? { nil }
}

public enum SpokenReference {

    /// How many rivals a refusal names before it stops listing. Ported
    /// unchanged from `PageElementResolver.spokenRivalLimit`.
    public static let spokenRivalLimit = 3

    /// Positions into the caller's own `elements` array — see this file's
    /// header for why an index, not a generic enum, is the return shape.
    public enum Outcome: Sendable, Equatable {
        case one(Int)
        /// More than one thing fits, and picking would be a guess.
        case ambiguous([Int])
        case none
    }

    /// See `PageElementResolver.resolve` for the full rationale of
    /// `preferShortestOnTie`; this is that same ladder, rung for rung.
    /// THE POOL A PHRASE IS ASKING ABOUT: the rows of the kind it named, in the
    /// part of the page it named.
    ///
    /// PIN: TWO FILTERS, ONE PLACE, so `resolve` and `reached` cannot disagree
    /// about what "the third link in the sidebar" is counting. Either filter
    /// applies only when the phrase names something the pool actually holds —
    /// see `PageRegion.named(in:among:)` for why naming a region a page has none
    /// of has to be a miss rather than a silent widening.
    /// `indices` is nil when the phrase named a PLACE this page does not have —
    /// a miss, not a pool. Widening back to the whole page there is how "the
    /// third link in the sidebar" would come to open the third link in the
    /// article, which is the wrong row said confidently.
    static func pool<Element: SpokenReferable>(
        phrase rawPhrase: String, among elements: [Element]
    ) -> (kind: PageElementKind?, region: PageRegion?, indices: [Int]?) {
        let kind = offeredKind(namedIn: rawPhrase, among: elements)
        let present = Set(elements.compactMap(\.spokenRegion))
        let region = present.isEmpty
            ? nil : PageRegion.named(in: rawPhrase, among: present)
        // NAMED A PLACE, JUST NOT ONE OF THESE. Only asked of a pool that HAS
        // places: a native window's roster has none, and a phrase saying "on the
        // right" about one is a name, exactly as it was before regions existed.
        if region == nil, !present.isEmpty,
           PageRegion.named(in: rawPhrase, among: Set(PageRegion.allCases)) != nil {
            return (kind, nil, nil)
        }
        var indices = Array(elements.indices)
        if let kind { indices = indices.filter { elements[$0].spokenKind == kind } }
        if let region { indices = indices.filter { elements[$0].spokenRegion == region } }
        return (kind, region, indices)
    }

    public static func resolve<Element: SpokenReferable>(
        phrase rawPhrase: String,
        among elements: [Element],
        preferShortestOnTie: Bool = true
    ) -> Outcome {
        let phrase = normalized(rawPhrase)
        guard !phrase.isEmpty, !elements.isEmpty else { return .none }

        let (kind, region, pooled) = pool(phrase: rawPhrase, among: elements)
        guard let poolIndices = pooled else { return .none }

        // 1 — position. "The third video" / "the last one".
        if let ordinal = SpokenOrdinal.value(in: rawPhrase) {
            guard !poolIndices.isEmpty else { return .none }
            if ordinal == -1 { return .one(poolIndices[poolIndices.count - 1]) }
            guard ordinal >= 1, ordinal <= poolIndices.count else { return .none }
            return .one(poolIndices[ordinal - 1])
        }

        let needle = stripped(phrase, of: kind, in: region)
        guard !needle.isEmpty else {
            // They named only a category: unambiguous only if the pool
            // holds exactly one of them.
            if poolIndices.count == 1 { return .one(poolIndices[0]) }
            return poolIndices.isEmpty
                ? .none : .ambiguous(Array(poolIndices.prefix(spokenRivalLimit)))
        }

        // 2 — an exact name. Rivals here are UNCAPPED — see this file's
        // header.
        let exact = poolIndices.filter { normalized(elements[$0].spokenLabel) == needle }
        if exact.count == 1 { return .one(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }

        // 3 — containment, either direction.
        let contained = poolIndices.filter { index in
            let label = normalized(elements[index].spokenLabel)
            return label.contains(needle) || needle.contains(label)
        }
        if contained.count == 1 { return .one(contained[0]) }
        if contained.count > 1 {
            guard preferShortestOnTie else {
                return .ambiguous(Array(contained.prefix(spokenRivalLimit)))
            }
            let shortest = contained.map { elements[$0].spokenLabel.count }.min() ?? 0
            let tightest = contained.filter { elements[$0].spokenLabel.count == shortest }
            if tightest.count == 1 { return .one(tightest[0]) }
            return .ambiguous(Array(contained.prefix(spokenRivalLimit)))
        }

        // 4 — every spoken word present, somewhere, in one label only.
        let words = needle.split(separator: " ").map(String.init).filter { $0.count > 2 }
        if !words.isEmpty {
            let covered = poolIndices.filter { index in
                let label = normalized(elements[index].spokenLabel)
                return words.allSatisfy { label.contains($0) }
            }
            if covered.count == 1 { return .one(covered[0]) }
            if covered.count > 1 {
                return .ambiguous(Array(covered.prefix(spokenRivalLimit)))
            }
        }

        return .none
    }

    // MARK: - Which rung answered

    /// The rung of the ladder that reached a row, for a caller that RANKS rather than
    /// resolves.
    public enum Rung: String, Sendable, Equatable, CaseIterable {
        /// "the third video" — a position the person spoke.
        case ordinal
        /// The phrase named only a kind, and these are the rows of it.
        case kindOnly
        case exact
        case contained
        /// Every spoken word longer than two letters appears in the label.
        case allWords
    }

    /// THE SAME LADDER, SAYING WHICH RUNG ANSWERED — and every row that rung reached,
    /// uncapped.
    ///
    /// PIN: NOT A SECOND LADDER. `resolve` answers "which one", which is what a verb
    /// needs; a router needs "how well did each row answer", because a naming hit is one
    /// term of an evidence score sitting beside meaning and structure. Both walk the same
    /// rungs over the same normalization, and `SpokenReferenceTests` pins that the rows
    /// this reaches are the rows `resolve` picks from — a drift between them would let
    /// the router rank on a match the resolver would never have made.
    /// UNCAPPED, because `spokenRivalLimit` is about how many rivals a SENTENCE names,
    /// and this feeds a table rather than a sentence.
    public static func reached<Element: SpokenReferable>(
        phrase rawPhrase: String, among elements: [Element]
    ) -> (rung: Rung, indices: [Int])? {
        let phrase = normalized(rawPhrase)
        guard !phrase.isEmpty, !elements.isEmpty else { return nil }

        let (kind, region, pooled) = pool(phrase: rawPhrase, among: elements)
        guard let poolIndices = pooled else { return nil }
        // A KIND THE PAGE DOES NOT HOLD IS NOT A POOL TO COUNT.
        //
        // PIN: MEASURED. "The first video" on a page whose rows the reading classified as
        // nothing in particular counted the rows AT LARGE and answered with the first of
        // them — a search box, as it happened. Naming a category the page has none of is
        // not a position; it is a miss, and the caller is owed that rather than the top of
        // an unrelated list. `resolve` keeps the older, more forgiving reading for the
        // native-window lane, where the roster is an Accessibility tree and its kinds are
        // told rather than inferred.
        if kind == nil,
           PageElementKindDerivation.offeredKind(
               namedIn: rawPhrase, offering: Set(PageElementKind.allCases)) != nil {
            return nil
        }
        // A REGION THE PAGE DOES NOT HOLD IS A MISS FOR THE SAME REASON — and
        // one it DOES hold that is empty of the named kind is too.
        if region != nil, poolIndices.isEmpty { return nil }

        if let ordinal = SpokenOrdinal.value(in: rawPhrase) {
            guard !poolIndices.isEmpty else { return nil }
            if ordinal == -1 { return (.ordinal, [poolIndices[poolIndices.count - 1]]) }
            guard ordinal >= 1, ordinal <= poolIndices.count else { return nil }
            return (.ordinal, [poolIndices[ordinal - 1]])
        }

        let needle = stripped(phrase, of: kind, in: region)
        guard !needle.isEmpty else {
            return poolIndices.isEmpty ? nil : (.kindOnly, poolIndices)
        }

        let exact = poolIndices.filter { normalized(elements[$0].spokenLabel) == needle }
        if !exact.isEmpty { return (.exact, exact) }

        let contained = poolIndices.filter { index in
            let label = normalized(elements[index].spokenLabel)
            return label.contains(needle) || needle.contains(label)
        }
        if !contained.isEmpty { return (.contained, contained) }

        let words = needle.split(separator: " ").map(String.init).filter { $0.count > 2 }
        if !words.isEmpty {
            let covered = poolIndices.filter { index in
                let label = normalized(elements[index].spokenLabel)
                return words.allSatisfy { label.contains($0) }
            }
            if !covered.isEmpty { return (.allWords, covered) }
        }
        return nil
    }

    // MARK: - Spoken outcomes

    /// Labels get long; a spoken sentence should not. Ported unchanged from
    /// `PageElementResolver.shortened`.
    public static func shortened(_ label: String, limit: Int = 60) -> String {
        label.count <= limit ? label : String(label.prefix(limit)) + "…"
    }

    /// "A", "A and B", "A, B, and C" — the joiner every lane's refusal
    /// wording shares. Ported out of `PageElementResolver.ambiguityRefusal`.
    public static func spokenList(_ named: [String]) -> String {
        switch named.count {
        case 0, 1: return named.first ?? ""
        case 2: return named.joined(separator: " and ")
        default:
            return named.dropLast().joined(separator: ", ") + ", and " + (named.last ?? "")
        }
    }

    // MARK: - Normalization

    /// One spelling for the whole system — see `ElementIdentity.normalized`.
    /// A second copy here would let a spoken match and an element key drift.
    public static func normalized(_ value: String) -> String {
        ElementIdentity.normalized(value)
    }

    /// Remove the words that classified the target rather than named it — the kind word
    /// itself and the determiners around it.
    /// PIN: THE REGION'S WORDS COME OUT WITH THE KIND'S, and the preposition
    /// that led to them. "The Donate link in the sidebar" is a NAME — "Donate" —
    /// said about a part of the page, and a needle still carrying "in the
    /// sidebar" matches no label anywhere.
    static func stripped(
        _ phrase: String, of kind: PageElementKind?, in region: PageRegion? = nil
    ) -> String {
        var value = phrase
        if region != nil {
            for preposition in ["in the", "on the", "at the", "down the", "across the",
                                "along the", "inside the", "in", "on", "at"] {
                value = value.replacingOccurrences(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: preposition))\\b",
                    with: " ",
                    options: .regularExpression)
            }
        }
        let noise = ["the", "that", "this", "a", "an", "one", "please"]
            + (kind?.admittingWords.flatMap { [$0, $0 + "s"] } ?? [])
            + (region?.admittingWords.flatMap { [$0, $0 + "s"] } ?? [])
        for word in noise.sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                with: " ",
                options: .regularExpression)
        }
        for verb in ["play", "watch", "open", "click", "press", "go to",
                     "let s", "lets", "show me", "take me to", "select"] {
            value = value.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: verb))\\b",
                with: " ",
                options: .regularExpression)
        }
        return value
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Does a spoken phrase name one of the kinds this pool actually offers?
    /// Generalized from `PageElementKindDerivation.offeredKind(namedIn:among:)`
    /// to work over any `SpokenReferable` pool, not just `[PageElement]`.
    static func offeredKind<Element: SpokenReferable>(
        namedIn phrase: String, among elements: [Element]
    ) -> PageElementKind? {
        let present = Set(elements.compactMap(\.spokenKind))
        return PageElementKindDerivation.offeredKind(namedIn: phrase, offering: present)
    }
}

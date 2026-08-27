//
//  PageElementResolver.swift
//  MaryAdapter
//
//  ONE PHRASE, ONE THING — OR AN HONEST REFUSAL.
//
//  This is the browsing lane's answer to a question the other two flagships
//  already answer. Xcode's locator returns `found / ambiguous / notFound` and
//  refuses with a count ("There are 3 things called X — tell me which");
//  `PassageResolver` re-locates by text or refuses, and never "accepts the
//  closest of several". The browser had no equivalent because it had nothing
//  to resolve AGAINST. `PageElementReader` supplies that; this decides.
//
//  THE LADDER ITSELF NOW LIVES IN `SpokenReference.swift` — lifted out so
//  the snapshot lane's `AXScreenElement` can run the identical, measured
//  logic instead of a second hand-written copy. This file is what stays:
//  `PageElement`'s own conformance, `PageElementResolution`'s exact shape,
//  and the browser lane's spoken wording, all byte-compatible with what
//  they were before the lift. See `SpokenReference.swift`'s header for the
//  ladder's rungs and the doctrine behind each one.
//
//  ORDINALS ARE ONLY HONEST OVER A LIVE LISTING. `ReferenceResolver`'s rule
//  is that a counting ordinal without one must refuse rather than pick an
//  index; that rule is honored by construction here, because every caller
//  enumerates the page immediately before resolving.
//

import Foundation

extension PageElement: SpokenReferable {
    public var spokenLabel: String { label }
    public var spokenKind: PageElementKind? { kind }
}

public enum PageElementResolution: Sendable, Equatable {
    case one(PageElement)
    /// More than one thing fits, and picking would be a guess. Carries the
    /// rivals so the refusal can name them.
    case ambiguous([PageElement])
    case none
}

public enum PageElementResolver {

    /// How many rivals a refusal names before it stops listing.
    public static let spokenRivalLimit = SpokenReference.spokenRivalLimit

    /// `preferShortestOnTie` — WHO GETS THE BENEFIT OF THE DOUBT when several
    /// labels contain the phrase.
    ///
    /// For a NAME it is right to prefer the shortest: "Lesson 1" and the card
    /// that restates it at length are one thing said twice, and the rung's own
    /// comment says so. For a GOAL it is wrong, and the difference is not
    /// stylistic — "skip that" contains both "Skip Ads" and "Skip Intro", the
    /// shorter one wins by two characters, and Mary presses a coin toss.
    /// `AffordanceResolver` passes false and gets a refusal that names both;
    /// `click_on_page` keeps the default and behaves exactly as it always has.
    public static func resolve(
        phrase rawPhrase: String,
        in elements: [PageElement],
        preferShortestOnTie: Bool = true
    ) -> PageElementResolution {
        switch SpokenReference.resolve(
            phrase: rawPhrase, among: elements, preferShortestOnTie: preferShortestOnTie
        ) {
        case .one(let index): return .one(elements[index])
        case .ambiguous(let indices): return .ambiguous(indices.map { elements[$0] })
        case .none: return .none
        }
    }

    // MARK: - Spoken outcomes

    /// The refusal, in the shape the other flagships use: state the count and
    /// the rivals, and stop. No "be more specific" — the sentence itself is
    /// what makes the next turn easy.
    public static func ambiguityRefusal(
        _ rivals: [PageElement], phrase: String
    ) -> String {
        let named = rivals.prefix(spokenRivalLimit)
            .map { "\"\(shortened($0.label))\"" }
        let list = SpokenReference.spokenList(Array(named))
        return "There are \(rivals.count) things on the page matching \(phrase) — \(list). Which one?"
    }

    public static func missRefusal(phrase: String) -> String {
        "I can't find \(phrase) on this page. Ask me what's on the page and I'll read you what I can see."
    }

    /// Labels get long; a spoken sentence should not.
    public static func shortened(
        _ label: String, limit: Int = 60
    ) -> String {
        SpokenReference.shortened(label, limit: limit)
    }

    // MARK: - Normalization

    public static func normalized(_ value: String) -> String {
        SpokenReference.normalized(value)
    }

    /// RE-FIND AN ELEMENT IN A FRESH READ — the rule every actuation path runs
    /// before touching anything, because a frame is a coordinate and a window
    /// that re-laid out has moved its controls.
    ///
    /// A URL is the strongest handle when there is one; otherwise label and
    /// role together, which is the same pair `identity` is spelled from.
    /// Lived on the browser's recipes in Bonnie and is not browser-shaped:
    /// nothing in it knows what a page is.
    static func relocate(_ element: PageElement, in fresh: [PageElement]) -> PageElement? {
        if let url = element.url,
           let match = fresh.first(where: { $0.url == url }) {
            return match
        }
        return fresh.first {
            $0.label.caseInsensitiveCompare(element.label) == .orderedSame
                && $0.role == element.role
        }
    }
}

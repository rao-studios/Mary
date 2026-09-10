//
//  PageElementResolver.swift
//  MaryPlugin
//
//  WHAT: One phrase, one PageElement — or an honest refusal.
//  IN:   SpokenReference ladder  OUT: browsing skills
//  PIN:  Ordinals are only honest over a live listing.

import Foundation
import MaryComputerUse

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

    /// `preferShortestOnTie` — WHO GETS THE BENEFIT OF THE DOUBT when several labels
    /// contain the phrase.
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

    /// RE-FIND AN ELEMENT IN A FRESH READ — the rule every actuation path runs before
    /// touching anything, because a frame is.
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

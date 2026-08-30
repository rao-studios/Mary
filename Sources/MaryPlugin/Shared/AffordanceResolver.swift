//
//  AffordanceResolver.swift
//  MaryAdapter
//
//  WHAT: Phrase → one affordance, or an honest refusal.
//  IN:   SpokenReference  OUT: AffordancePlugin

import Foundation
import MaryAmbient

public enum AffordanceResolver {

    /// Scores this close to the winner are a genuine tie. Deliberately narrow: the gate's
    /// lexical floors are spaced 0.03 apart (0.98/0.95/0.92/0.88), so a band of exactly
    /// that width treats same-basis rivals as rivals and never merges two different bases.
    public static let tieBand: Float = 0.03

    // MARK: - Identity

    /// The id an element keeps across a publish and a lookup. NOT the ordinal, which is a
    /// position and re-flows.
    public static func identity(of element: PageElement) -> String {
        let label = PageElementResolver.normalized(element.label)
        return "\(element.role.lowercased())|\(label)"
    }

    /// What ambient memory holds about a page's offerings.
    public static func affordances(
        from elements: [PageElement]
    ) -> [AmbientAffordance] {
        elements.enumerated().map { index, element in
            AmbientAffordance(
                id: identity(of: element),
                label: element.label,
                roleWord: element.kind.spokenWord,
                ordinal: index + 1,
                isEnabled: element.isEnabled,
                help: element.help)
        }
    }

    /// Publish one reading into the scope's slate. Wholesale, like every other
    /// `noteElements` caller: a page's offerings are replaced, never accumulated, because a
    /// control that has scrolled away is not a control the user can be offered.
    public static func publish(
        _ elements: [PageElement],
        scope: AmbientElementScope,
        store: AmbientElementIndexStore = .shared
    ) {
        store.noteElements(
            AffordanceRule.records(
                for: affordances(from: elements), scope: scope),
            scope: scope)
    }

    // MARK: - The ladder

    /// Resolve a spoken goal against a freshly read slate. `scope` must already have been
    /// published from THESE elements.
    public static func resolve(
        goal: String,
        in elements: [PageElement],
        scope: AmbientElementScope,
        store: AmbientElementIndexStore = .shared
    ) -> PageElementResolution {
        let phrase = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !elements.isEmpty else { return .none }

        // 1 — the naming ladder, first, and strict about ties. IT REACHES FURTHER THAN
        // EXPECTED, which is worth recording because it changes what this rung is for.
        let named = PageElementResolver.resolve(
            phrase: phrase, in: elements, preferShortestOnTie: false)
        if case .one = named { return named }

        // 2 — meaning. Only pressable things: a goal is something to DO.
        let ranked = AmbientReferenceGate.rank(
            phrase: phrase, scope: scope, requires: .pressable, store: store)
        let byIdentity = Dictionary(
            elements.map { (identity(of: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        let candidates = ranked.compactMap { entry -> (PageElement, Float)? in
            guard let element = byIdentity[entry.record.elementID],
                  element.isEnabled,
                  AffordanceDistinctiveness.survives(entry, phrase: phrase)
            else { return nil }
            return (element, entry.score)
        }
        guard let best = candidates.first else {
            // The naming ladder's own verdict stands when meaning adds
            // nothing — an ambiguity it found is still an ambiguity.
            return named
        }
        // NO TIEBREAK, DELIBERATELY. `PageElementResolver`'s containment rung prefers the
        // shortest label, on the stated grounds that a card and its own longer restatement
        // are not two things.
        let tied = candidates.filter { $0.1 >= best.1 - tieBand }
        if tied.count > 1 {
            return .ambiguous(
                Array(tied.prefix(PageElementResolver.spokenRivalLimit)
                    .map(\.0)))
        }
        return .one(best.0)
    }

}

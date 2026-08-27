//
//  AffordanceResolver.swift
//  MaryAdapter
//
//  A GOAL, RESOLVED AGAINST WHAT THE SCREEN IS OFFERING.
//
//  `PageElementResolver` answers "which thing did they NAME". This answers
//  the question that broke live: "which thing WOULD DO WHAT THEY ASKED".
//  They are different questions and both are needed. "Play the third video"
//  names a thing; "can you skip the ad" names an outcome, and the control
//  that delivers it is labelled "Skip Ads" — a spelling no lexical ladder
//  reaches, because containment fails on "the", and the all-words rung fails
//  on "ad" against "ads".
//
//  SO THE LEXICAL LADDER GOES FIRST, UNCHANGED. Every phrase that resolved
//  before still resolves the same way, by the same code — ordinals, exact
//  names, containment. Only a phrase the ladder MISSES reaches the meaning
//  rung, so nothing that works today can be re-decided by an embedding.
//
//  THE MEANING RUNG IS THE ONE THE AMBIENT WORLD ALREADY OWNS.
//  `AmbientReferenceGate` has ranked canvas layers, passages and facts
//  against spoken phrases since the element index shipped; a page's buttons
//  are one more slate, published under their own scope so a press can never
//  land on a paragraph and a paragraph query can never rank a button.
//
//  ONE GUARD RIDES ON TOP, AND IT IS SHARED. The gate's name floor fires
//  when the phrase contains ANY word of an element's name — right for a
//  layer called "Header", dangerous for a button called "The Defiance Act"
//  against "skip the ad". `AmbientAddressProbe` met the same hazard on tab
//  titles and answered it with a distinctiveness test rather than a higher
//  threshold. `AffordanceDistinctiveness` is that test, and it lives in
//  MaryAmbient beside the probe rather than here, so the sentence that
//  NAMES a control in a nudge and the resolution that PRESSES it can never
//  disagree about which controls exist.
//

import Foundation
import MaryAmbient

public enum AffordanceResolver {

    /// Scores this close to the winner are a genuine tie. Deliberately
    /// narrow: the gate's lexical floors are spaced 0.03 apart
    /// (0.98/0.95/0.92/0.88), so a band of exactly that width treats
    /// same-basis rivals as rivals and never merges two different bases.
    public static let tieBand: Float = 0.03

    // MARK: - Identity

    /// The id an element keeps across a publish and a lookup.
    ///
    /// NOT the ordinal, which is a position and re-flows. Role plus label is
    /// what stays true of a control between two reads a second apart, and the
    /// hands re-find the real element by that same identity before touching
    /// anything (`relocate`), so a collision costs a re-press of an identical
    /// twin rather than a press of the wrong thing.
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

    /// Publish one reading into the scope's slate. Wholesale, like every
    /// other `noteElements` caller: a page's offerings are replaced, never
    /// accumulated, because a control that has scrolled away is not a
    /// control the user can be offered.
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

    /// Resolve a spoken goal against a freshly read slate.
    ///
    /// `scope` must already have been published from THESE elements — the
    /// caller does it, so a resolution never silently rewrites the ambient
    /// world as a side effect of asking a question.
    public static func resolve(
        goal: String,
        in elements: [PageElement],
        scope: AmbientElementScope,
        store: AmbientElementIndexStore = .shared
    ) -> PageElementResolution {
        let phrase = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !elements.isEmpty else { return .none }

        // 1 — the naming ladder, first, and strict about ties.
        //
        // IT REACHES FURTHER THAN EXPECTED, which is worth recording because
        // it changes what this rung is for. "skip the ad" DOES resolve
        // "Skip Ads" here: `stripped` drops "the", and "skip ads" contains
        // "skip ad". So the lexical ladder was never the reason the live turn
        // failed — nothing had told it the button existed. The meaning rung
        // below still earns its place on the phrasings containment cannot
        // reach ("can you skip the ad", where the needle carries "can you").
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
        // NO TIEBREAK, DELIBERATELY. `PageElementResolver`'s containment rung
        // prefers the shortest label, on the stated grounds that a card and
        // its own longer restatement are not two things. That reasoning does
        // not reach here: "Skip Ads" and "Skip Intro" are two things, and
        // picking the shorter would press one of them on a coin toss. A
        // refusal that names both is the whole doctrine of this lane.
        let tied = candidates.filter { $0.1 >= best.1 - tieBand }
        if tied.count > 1 {
            return .ambiguous(
                Array(tied.prefix(PageElementResolver.spokenRivalLimit)
                    .map(\.0)))
        }
        return .one(best.0)
    }

}

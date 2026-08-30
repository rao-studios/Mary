//
//  AffordanceProbe.swift
//  MaryAmbient
//
//  WHAT: Does the screen already offer what they just asked for?
//  IN:   AmbientElementIndexStore affordance slates
//  OUT:  AffordanceCandidate (nudge). Sibling: AmbientAddressProbe (which application).
//  PIN:  Adds work, never removes reach. A miss changes nothing.
//
import Foundation

/// What the screen is offering that might serve a spoken goal.
public struct AffordanceCandidate: Sendable, Equatable {
    public var scope: AmbientElementScope
    /// The control's own label, best first. Named aloud in a nudge, so it is
    /// the words the control uses rather than anything Mary invented.
    public var labels: [String]
    /// The best score any of them reached — the confidence a deterministic
    /// last rung can gate on.
    public var score: Float

    public init(scope: AmbientElementScope, labels: [String], score: Float) {
        self.scope = scope
        self.labels = labels
        self.score = score
    }
}

public enum AffordanceProbe {

    /// How stale an affordance slate may be and still describe the screen.
    /// Deliberately short — much shorter than the address probe's five
    /// minutes, because a tab title survives a scroll and a button does not.
    public static let freshnessHorizon: TimeInterval = 90

    /// How many rivals a nudge names. `PageElementResolver.spokenRivalLimit`'s
    /// number, for the same reason: a list nobody can hold is not an offer.
    public static let namedLimit = 3

    /// The score a candidate must reach before a DETERMINISTIC act may be dispatched on it
    /// without the model's agreement.
    public static let confidentFloor: Float = 0.90

    /// Affordance slates the world has published recently.
    static func scopes(
        store: AmbientElementIndexStore, at now: Date
    ) -> [AmbientElementScope] {
        store.activeScopes(freshWithin: freshnessHorizon, at: now)
            .filter { $0.key.hasSuffix(AmbientElementScope.affordanceSuffix) }
    }

    /// The best-serving control for this goal, if the screen offers one. Ranked across every
    /// fresh affordance slate rather than only the lead place's: a slate exists only where a
    /// perception lane published one, so candidacy already follows publication.
    public static func candidate(
        for utterance: String,
        store: AmbientElementIndexStore = .shared,
        at now: Date = Date()
    ) -> AffordanceCandidate? {
        let phrase = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count >= 3 else { return nil }
        var best: AffordanceCandidate?
        for scope in scopes(store: store, at: now) {
            let ranked = AmbientReferenceGate.rank(
                phrase: phrase, scope: scope,
                requires: .pressable, store: store)
                .filter { AffordanceDistinctiveness.survives($0, phrase: phrase) }
            guard let top = ranked.first else { continue }
            guard best == nil || top.score > (best?.score ?? 0) else { continue }
            best = AffordanceCandidate(
                scope: scope,
                labels: ranked.prefix(namedLimit).map {
                    $0.record.name ?? $0.record.displaySummary
                },
                score: top.score)
        }
        return best
    }
}

/// THE ONE GUARD, shared with `AffordanceResolver` so a nudge can never name a control the
/// act would then refuse to press. The gate's lexical floors fire on ANY shared word of a
/// name. Right for a layer called "Header".
public enum AffordanceDistinctiveness {

    /// `AmbientAddressProbe`'s G3 length, for its reason: "Home" and "New Tab"
    /// must never address, and neither must "Ad".
    public static let minimumWordLength = 4

    public static func survives(
        _ entry: RankedAmbientElement, phrase: String
    ) -> Bool {
        switch entry.basis {
        case .semantic:
            return true
        case .lexicalKind, .lexicalName, .lexicalSynonym:
            let spoken = Set(words(in: phrase))
            return words(in: entry.record.name ?? entry.record.kindWord)
                .contains { word in
                    spoken.contains(word)
                        && word.count >= minimumWordLength
                        && !AmbientRanker.stopWords.contains(word)
                }
        }
    }

    public static func words(in value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

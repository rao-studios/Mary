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
    public static func resolve<Element: SpokenReferable>(
        phrase rawPhrase: String,
        among elements: [Element],
        preferShortestOnTie: Bool = true
    ) -> Outcome {
        let phrase = normalized(rawPhrase)
        guard !phrase.isEmpty, !elements.isEmpty else { return .none }

        let kind = offeredKind(namedIn: rawPhrase, among: elements)
        let poolIndices = kind.map { k in
            elements.indices.filter { elements[$0].spokenKind == k }
        } ?? Array(elements.indices)

        // 1 — position. "The third video" / "the last one".
        if let ordinal = SpokenOrdinal.value(in: rawPhrase) {
            guard !poolIndices.isEmpty else { return .none }
            if ordinal == -1 { return .one(poolIndices[poolIndices.count - 1]) }
            guard ordinal >= 1, ordinal <= poolIndices.count else { return .none }
            return .one(poolIndices[ordinal - 1])
        }

        let needle = stripped(phrase, of: kind)
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
    static func stripped(_ phrase: String, of kind: PageElementKind?) -> String {
        var value = phrase
        let noise = ["the", "that", "this", "a", "an", "one", "please"]
            + (kind?.admittingWords.flatMap { [$0, $0 + "s"] } ?? [])
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

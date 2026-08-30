//
//  AmbientReferenceGate.swift
//  MaryAmbient
//
//  WHAT: Front door — spoken referent → ranked ambient elements.
//  IN:   AmbientElementIndexStore
//  OUT:  resolution (best + runner-up)
//  PIN:  Lexicon is support, not the door. Filter by required capabilities.
//

import Foundation

/// One element, scored. `basis` says what carried it — the strongest
/// contributor — for briefs and traces.
public struct RankedAmbientElement: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        /// Embedding similarity alone.
        case semantic
        /// The phrase spoke the element's own kind word.
        case lexicalKind
        /// The phrase spoke the element's name.
        case lexicalName
        /// A closed-class synonym admitted the element's kind.
        case lexicalSynonym
    }
    public var record: AmbientElementRecord
    public var score: Float
    public var basis: Basis

    public init(record: AmbientElementRecord, score: Float, basis: Basis) {
        self.record = record
        self.score = score
        self.basis = basis
    }
}

public enum AmbientReferenceGate {

    /// Below this an element is not offered at all.
    public static let acceptanceThreshold: Float = 0.50

    /// Floors for lexical certainty.
    static let nameAndKindFloor: Float = 0.98
    static let kindFloor: Float = 0.95
    static let nameFloor: Float = 0.92
    static let synonymFloor: Float = 0.88

    /// THE FRONT DOOR. Ranks the scope's elements by relevancy to the phrase, keeps only those
    /// able to serve the invocation (`requires`), and returns them best-first.
    public static func rank(
        phrase: String,
        scope: AmbientElementScope,
        requires: AmbientElementCapabilities = [],
        store: AmbientElementIndexStore = .shared
    ) -> [RankedAmbientElement] {
        guard let index = store.index(for: scope) else { return [] }
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let semantic = store.queryVector(for: trimmed)
            .map(index.semanticScores(forQueryVector:)) ?? [:]

        let lowered = trimmed.lowercased()
        let words = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // The vocabulary for THIS scope's application, when an admitted package declares one. No
        // lexicon → the synonym floor and the precision veto stand down; kind and name floors
        // survive because they need no table (a provider's own kind word self-matches).
        let lexicon = AmbientArtifactLexiconProvider.lexicon(forApplication: scope.key)
        // The union of kinds the phrase's CLOSED-CLASS words admit; nil when
        // the phrase speaks no known kind word and the veto stands down.
        let admittedKinds: Set<String>? = {
            guard let lexicon else { return nil }
            let admissions = words.compactMap { lexicon.admittedKinds(for: $0) }
            guard !admissions.isEmpty else { return nil }
            return admissions.reduce(into: Set<String>()) { $0.formUnion($1) }
        }()

        var ranked: [(element: RankedAmbientElement, order: Int)] = []
        for (order, record) in index.records.enumerated() {
            guard record.capabilities.isSuperset(of: requires) else { continue }
            var score = semantic[record.elementID] ?? 0
            var basis = RankedAmbientElement.Basis.semantic

            let namedHit = nameMatches(record.name, in: lowered)
            let kindHit = words.contains(record.kindWord)
            let synonymHit = !kindHit
                && (lexicon?.phrase(lowered, admits: record.kindWord) ?? false)
            let floor: (Float, RankedAmbientElement.Basis)? = {
                if namedHit, kindHit || synonymHit {
                    return (nameAndKindFloor, .lexicalName)
                }
                if kindHit { return (kindFloor, .lexicalKind) }
                if namedHit { return (nameFloor, .lexicalName) }
                if synonymHit { return (synonymFloor, .lexicalSynonym) }
                return nil
            }()
            if let (floorScore, floorBasis) = floor, score < floorScore {
                score = floorScore
                basis = floorBasis
            }

            // PRECISION VETO. The phrase spoke a known kind word; this element is of a known kind
            // those words do not admit — "rectangle" cannot mean an Oval however cozy the vectors.
            if let lexicon, let admittedKinds,
               lexicon.providerKinds.contains(record.kindWord),
               !admittedKinds.contains(record.kindWord),
               !namedHit {
                continue
            }

            guard score >= acceptanceThreshold else { continue }
            ranked.append((
                RankedAmbientElement(record: record, score: score, basis: basis),
                order))
        }
        return ranked
            .sorted { lhs, rhs in
                lhs.element.score != rhs.element.score
                    ? lhs.element.score > rhs.element.score
                    : lhs.order < rhs.order
            }
            .map(\.element)
    }

    /// Classification probe: does this word plausibly name ANY element of
    /// the scope? The cheap yes/no the cue classifier needs — one word
    /// vectorization plus dots, or lexicon floors in degraded mode.
    public static func names(
        _ word: String,
        inScope scope: AmbientElementScope,
        store: AmbientElementIndexStore = .shared
    ) -> Bool {
        !rank(phrase: word, scope: scope, store: store).isEmpty
    }

    /// Word-boundary containment of the element's name (whole or any word
    /// of it) in the phrase — "the header oval" matches a layer named
    /// "Header". Mirrors the ledger's historical matcher.
    static func nameMatches(_ name: String?, in phrase: String) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        if ReferenceResolver.mentions(name, in: phrase) { return true }
        return name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { ReferenceResolver.mentions(String($0), in: phrase) }
    }
}

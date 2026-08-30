//
//  SemanticAbilityRequestIndex.swift
//  MaryBrain
//
//  WHAT: Embedding recall for the Ability-request seam.
//  IN:   AbilityTriggerSchema corpus (authored package data)
//  OUT:  union with exact `requestedAbilities(in:)`
//  PIN:  Additive only; fails closed; never identifies a Skill.
//
import MaryAmbient
import Foundation

/// The vectorizer seam moved down to MaryAmbient (the ambient element
/// index shares it); these aliases keep this seam's vocabulary stable.
public typealias UtteranceVectorizer = AmbientTextVectorizer
public typealias NLUtteranceVectorizer = NLAmbientTextVectorizer

/// The prebuilt per-Ability corpus vectors plus the query path. Built once
/// per registry reload; immutable and Sendable thereafter.
public struct SemanticAbilityRequestIndex: Sendable {

    /// Cosine similarity at or above this requests the Ability. Calibrated
    /// with the opt-in harness (`MARY_EMBEDDING_CALIBRATION=1`); precision
    /// matters more than recall here — a false request pollutes the roster.
    public static let defaultPositiveThreshold: Float = 0.62
    /// A negative term this close to the best positive suppresses the
    /// request — the embedding shape of `negativeTokens`.
    public static let defaultNegativeMargin: Float = 0.05

    private struct Entry: Sendable {
        var abilityID: AbilityID
        var positives: [[Float]]
        var negatives: [[Float]]
    }

    private let entries: [Entry]
    private let vectorizer: any UtteranceVectorizer
    private let positiveThreshold: Float
    private let negativeMargin: Float

    /// Nil when nothing in the corpus vectorized — an index that can only
    /// say "no" is dead weight.
    public static func build(
        records: [AbilityPackageRecord],
        vectorizer: any UtteranceVectorizer,
        positiveThreshold: Float = defaultPositiveThreshold,
        negativeMargin: Float = defaultNegativeMargin
    ) -> SemanticAbilityRequestIndex? {
        var entries: [Entry] = []
        for record in records {
            let ability = record.package.ability
            let triggers = ability.triggers
            var positiveTerms = triggers.tokens + triggers.phrases + ability.aliases
            // Intent aliases are ids ("design-create-shape"); speak them as
            // words so the sentence embedding sees language, not slugs.
            positiveTerms += triggers.intentAliases.map {
                $0.replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: ".", with: " ")
            }
            // Fixtures widen only Ability NOMINATION. They never identify a Skill or operation here
            positiveTerms += record.package.fixtures
                .filter { $0.expectedDisposition == "route" }
                .map(\.utterance)
            if !ability.summary.isEmpty { positiveTerms.append(ability.summary) }
            let positives = positiveTerms.compactMap {
                vectorizer.vector(for: $0).map(Self.normalized)
            }
            guard !positives.isEmpty else { continue }
            let negatives = triggers.negativeTokens.compactMap {
                vectorizer.vector(for: $0).map(Self.normalized)
            }
            entries.append(Entry(
                abilityID: ability.id,
                positives: positives,
                negatives: negatives))
        }
        guard !entries.isEmpty else { return nil }
        return SemanticAbilityRequestIndex(
            entries: entries,
            vectorizer: vectorizer,
            positiveThreshold: positiveThreshold,
            negativeMargin: negativeMargin)
    }

    private init(
        entries: [Entry],
        vectorizer: any UtteranceVectorizer,
        positiveThreshold: Float,
        negativeMargin: Float
    ) {
        self.entries = entries
        self.vectorizer = vectorizer
        self.positiveThreshold = positiveThreshold
        self.negativeMargin = negativeMargin
    }

    /// Embedding-only recall. Callers UNION this with the exact matches —
    /// it must never be consulted to veto them.
    public func requestedAbilities(in utterance: String) -> Set<AbilityID> {
        guard let raw = vectorizer.vector(for: utterance) else { return [] }
        let query = Self.normalized(raw)
        var requested: Set<AbilityID> = []
        for entry in entries {
            let best = entry.positives
                .map { Self.dot($0, query) }
                .max() ?? -1
            guard best >= positiveThreshold else { continue }
            let bestNegative = entry.negatives
                .map { Self.dot($0, query) }
                .max() ?? -1
            guard best - bestNegative >= negativeMargin else { continue }
            requested.insert(entry.abilityID)
        }
        return requested
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return -1 }
        var total: Float = 0
        for index in lhs.indices { total += lhs[index] * rhs[index] }
        return total
    }
}

//
//  SemanticAbilityRequestIndex.swift
//  MaryBrain
//
//  WHAT: Embedding recall for the Ability-request seam.
//  IN:   AbilityTriggerSchema corpus (authored package data)
//  OUT:  requestedAbilities when the index exists
//  PIN:  Tokens seed the corpus; they are not a second matcher.
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

    /// How far below the LEADER an Ability may sit and still be requested.
    ///
    /// MEASURED, NOT GUESSED (`EmbeddingCalibrationTests`, real NLEmbedding).
    /// Seven similar applications all clear a 0.62 floor on an app-shaped
    /// sentence, so a floor alone recalled three of them for "read me this
    /// browser tab". The gaps say where the line is: the genuine sibling
    /// (chrome, −0.043 behind safari) belongs; the bystander (pages, −0.068)
    /// does not.
    ///
    /// WHAT THIS CANNOT FIX, stated so nobody mistakes it for a cure: a WRONG
    /// LEADER. "What is my manuscript app showing me" puts safari on top at
    /// 0.695, and a rule measured from the leader keeps whatever leads. That
    /// is a corpus problem (safari's own alias is "the browser"), not a
    /// margin problem.
    public static let defaultDominanceMargin: Float = 0.05

    private struct Entry: Sendable {
        var abilityID: AbilityID
        var positives: [[Float]]
        var negatives: [[Float]]
    }

    private let entries: [Entry]
    private let vectorizer: any UtteranceVectorizer
    private let positiveThreshold: Float
    private let negativeMargin: Float
    private let dominanceMargin: Float

    public var entryCount: Int { entries.count }

    /// Nil when nothing in the corpus vectorized — an index that can only
    /// say "no" is dead weight.
    public static func build(
        records: [AbilityPackageRecord],
        vectorizer: any UtteranceVectorizer,
        templates: UtteranceTemplateExpander? = nil,
        positiveThreshold: Float = defaultPositiveThreshold,
        negativeMargin: Float = defaultNegativeMargin,
        dominanceMargin: Float = defaultDominanceMargin
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
            // THE WHOLE SENTENCES THE PACKAGE ALREADY AUTHORED. `intentSeeds`
            // are keyed by intent because `SemanticIntentIndex` reads them that
            // way, but every one of them is also a sentence ABOUT this Ability
            // — which is exactly what this index scores. They were being
            // written, shipped and then ignored here: 30 sentences across the
            // two disciplines, while recall leaned on bare tokens.
            positiveTerms += triggers.intentSeeds.values.flatMap { $0 }
            // Fixtures widen only Ability NOMINATION. They never identify a Skill or operation here
            positiveTerms += record.package.fixtures
                .filter { $0.expectedDisposition == "route" }
                .map(\.utterance)
            if !ability.summary.isEmpty { positiveTerms.append(ability.summary) }
            // `{application}` becomes one sentence per pointable application.
            // A term with no slot passes through untouched.
            positiveTerms = templates?.expand(positiveTerms, for: ability.id)
                ?? positiveTerms
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
        let dim = entries.first?.positives.first?.count ?? 0
        let skipped = records.count - entries.count
        MaryBrain.turnLog.info(
            "embed generate — abilities=\(entries.count, privacy: .public) dim=\(dim, privacy: .public) skipped=\(skipped, privacy: .public)")
        return SemanticAbilityRequestIndex(
            entries: entries,
            vectorizer: vectorizer,
            positiveThreshold: positiveThreshold,
            negativeMargin: negativeMargin,
            dominanceMargin: dominanceMargin)
    }

    private init(
        entries: [Entry],
        vectorizer: any UtteranceVectorizer,
        positiveThreshold: Float,
        negativeMargin: Float,
        dominanceMargin: Float = defaultDominanceMargin
    ) {
        self.entries = entries
        self.vectorizer = vectorizer
        self.positiveThreshold = positiveThreshold
        self.negativeMargin = negativeMargin
        self.dominanceMargin = dominanceMargin
    }

    /// Embedding-only recall. Tokens and phrases seeded the corpus at build.
    ///
    /// TWO TESTS, NOT ONE: clear the floor, AND stay within `dominanceMargin`
    /// of whoever leads. On an app-shaped sentence half the installed
    /// expertise clears the floor together — the floor says "this could be
    /// about an application", only the gap says WHICH.
    public func requestedAbilities(in utterance: String) -> Set<AbilityID> {
        let scored = affinities(in: utterance).filter { $0.value >= positiveThreshold }
        guard let lead = scored.values.max() else { return [] }
        return Set(scored.filter { $0.value >= lead - dominanceMargin }.keys)
    }

    /// THE SCORED SIBLING of `requestedAbilities`, for consumers that RANK
    /// rather than admit — discipline selection needs to know which ability
    /// the words lean toward and by how much over the runner-up, which a
    /// thresholded set cannot say. Negative suppression still applies (a
    /// suppressed ability is absent, not low-scoring); the positive floor and
    /// the dominance margin are the caller's to choose — `discipline(in:)`
    /// applies its own, and must not have them applied twice.
    public func affinities(in utterance: String) -> [AbilityID: Float] {
        guard let raw = vectorizer.vector(for: RoutingQuery.firstLine(utterance)) else { return [:] }
        let query = Self.normalized(raw)
        var scores: [AbilityID: Float] = [:]
        for entry in entries {
            let best = entry.positives
                .map { Self.dot($0, query) }
                .max() ?? -1
            let bestNegative = entry.negatives
                .map { Self.dot($0, query) }
                .max() ?? -1
            guard best - bestNegative >= negativeMargin else { continue }
            scores[entry.abilityID] = best
        }
        return scores
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

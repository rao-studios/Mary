//
//  SemanticSkillRequestIndex.swift
//  MaryBrain
//
//  WHAT: Embedding recall one tier down — which Skill the utterance is about.
//  IN:   Skill trigger corpus
//  OUT:  affinities for the arbitrator
//  PIN:  Same four constraints as SemanticAbilityRequestIndex; additive only.
//
import MaryAmbient
import MaryFoundation
import Foundation

/// Per-Skill corpus vectors plus the query path. Built once per registry
/// reload; immutable and Sendable thereafter.
public struct SemanticSkillRequestIndex: Sendable {

    /// Below this, a Skill is not being talked about and contributes nothing.
    public static let defaultThreshold: Float = 0.62

    /// The most an embedding can add to a Skill's evidence.
    public static let maximumBonus: Int = 45

    private struct Entry: Sendable {
        var skillID: SkillID
        var positives: [[Float]]
    }

    private let entries: [Entry]
    private let vectorizer: any UtteranceVectorizer
    private let threshold: Float

    /// Nil when nothing vectorized — an index that can only say "no" is dead
    /// weight, and nil is the value every caller already degrades on.
    public static func build(
        records: [AbilityPackageRecord],
        vectorizer: any UtteranceVectorizer,
        threshold: Float = defaultThreshold
    ) -> SemanticSkillRequestIndex? {
        var entries: [Entry] = []
        for record in records {
            let fixtures = record.package.fixtures
                .filter { $0.expectedDisposition == "route" }
            for skill in record.package.skills {
                var terms: [String] = [skill.title, skill.summary]
                // The name the model already selects by, spoken as words:
                // "play_playlist" is not language, "play playlist" is.
                if let invocation = skill.modelExposure.invocationName {
                    terms.append(deslugged(invocation))
                }
                terms.append(deslugged(skill.id.rawValue))
                // The utterance arms the author already wrote into the routing
                // policy. They are exact matches there; here they are seeds for
                // everything that means the same thing and says it differently.
                if let eligibility = skill.routing.eligibility {
                    terms += utteranceValues(in: eligibility)
                }
                // THE FIELD THE ABILITY INDEX READS PAST. A route fixture that names this Skill is a package author stating, in a whole spoken sentence
                terms += fixtures
                    .filter { $0.expectedSkill == skill.id }
                    .map(\.utterance)

                let positives = terms
                    .filter { !$0.isEmpty }
                    .compactMap { vectorizer.vector(for: $0).map(Self.normalized) }
                guard !positives.isEmpty else { continue }
                entries.append(Entry(skillID: skill.id, positives: positives))
            }
        }
        guard !entries.isEmpty else { return nil }
        return SemanticSkillRequestIndex(
            entries: entries, vectorizer: vectorizer, threshold: threshold)
    }

    private init(
        entries: [Entry], vectorizer: any UtteranceVectorizer, threshold: Float
    ) {
        self.entries = entries
        self.vectorizer = vectorizer
        self.threshold = threshold
    }

    /// Best similarity per Skill, for every Skill that clears the floor.
    /// A SCORE RATHER THAN A SET, which is the whole difference from the Ability seam.
    public func affinities(in utterance: String) -> [SkillID: Float] {
        guard let raw = vectorizer.vector(for: utterance) else { return [:] }
        let query = Self.normalized(raw)
        var affinities: [SkillID: Float] = [:]
        for entry in entries {
            let best = entry.positives.map { Self.dot($0, query) }.max() ?? -1
            guard best >= threshold else { continue }
            affinities[entry.skillID] = best
        }
        return affinities
    }

    /// The bounded evidence contribution of one affinity. Zero at the floor,
    /// `maximumBonus` at a perfect match, and never negative — a Skill the
    /// embedding has no opinion about must score what it scores today.
    public static func bonus(for affinity: Float, threshold: Float = defaultThreshold) -> Int {
        guard affinity > threshold, threshold < 1 else { return 0 }
        let span = (affinity - threshold) / (1 - threshold)
        return Int((min(max(span, 0), 1) * Float(maximumBonus)).rounded())
    }

    // MARK: - Corpus helpers

    /// Ids are not language: "play-playlist" and "play_playlist" both have to
    /// reach a sentence model as the words a person would actually say.
    static func deslugged(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
    }

    /// Every `utteranceToken` / `utterancePhrase` value in a predicate tree.
    static func utteranceValues(in predicate: RoutingPredicate) -> [String] {
        switch predicate.kind {
        case .utteranceToken, .utterancePhrase:
            return predicate.value.map { [$0] } ?? []
        case .all, .any, .not:
            return predicate.children.flatMap { utteranceValues(in: $0) }
        default:
            return []
        }
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

//
//  SemanticSkillRequestIndex.swift
//  MaryBrain
//
//  EMBEDDING RECALL, ONE TIER DOWN. `SemanticAbilityRequestIndex` answers
//  "which Ability is this turn about" and stops there — its own header says
//  fixtures "never identify a Skill or operation here". That was the honest
//  scope of the ability seam, and it left a gap: below it, nothing matches
//  language at all. Skill election is typed evidence, and the last mile is the
//  model reading tool descriptions. So "put on my running mix" reaches
//  Multimedia and then competes among seven media tools on wording alone.
//
//  THIS IS THE SAME MECHANISM, AIMED AT SKILLS, and it inherits the same four
//  constraints for the same reasons:
//  - SYNCHRONOUS AND CHEAP: built at registry reload, off the turn path; a
//    query costs one vectorization and a few hundred dot products.
//  - FAILS CLOSED: no OS embedding asset, no index — nil everywhere degrades
//    to today's behavior byte for byte.
//  - ADDITIVE ONLY, and here that word has to be enforced rather than
//    asserted, because a Skill tier has something the Ability tier does not:
//    an eligibility gate. So this returns a SCORE, never a verdict, and its
//    one consumer adds it into `AbilityRoutingEvidenceScore.total`. It is
//    never read by `isEligible` and never by `excludes`. An affinity of zero
//    scores exactly what the Skill scores today.
//  - DETERMINISTIC TESTS: `NLEmbedding` varies by OS build, so the vectorizer
//    stays a protocol and CI asserts through a fake.
//
//  THE CORPUS IS DATA THAT ALREADY EXISTS. No schema change, no new validator,
//  nothing for a package author to learn: a Skill's title and summary, the
//  invocation name the model already sees, the utterance predicates its
//  routing policy already admits, and the package's own route fixtures — which
//  have carried an `expectedSkill` all along that the ability index reads past.
//

import MaryAmbient
import MaryFoundation
import Foundation

/// Per-Skill corpus vectors plus the query path. Built once per registry
/// reload; immutable and Sendable thereafter.
public struct SemanticSkillRequestIndex: Sendable {

    /// Below this, a Skill is not being talked about and contributes nothing.
    /// Deliberately the same floor the Ability index uses — the two ask the
    /// same question of the same model, and one number is easier to calibrate
    /// than two.
    public static let defaultThreshold: Float = 0.62

    /// The most an embedding can add to a Skill's evidence.
    ///
    /// UNDER `utterancePhrase`'s 50, ON PURPOSE. An authored phrase is a
    /// package saying "this is what those words mean"; a similarity is a guess
    /// that they might. When the two disagree the author has to win, or
    /// authoring stops being worth doing.
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
                // THE FIELD THE ABILITY INDEX READS PAST. A route fixture that
                // names this Skill is a package author stating, in a whole
                // spoken sentence, that these words mean this Skill — the best
                // training text in the package, and until now it was only ever
                // used to widen Ability nomination.
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
    ///
    /// A SCORE RATHER THAN A SET, which is the whole difference from the
    /// Ability seam. That one returns membership because its consumer unions;
    /// this one's consumer ranks, and collapsing a similarity to a boolean
    /// here would make a Skill that barely cleared the floor indistinguishable
    /// from one the utterance is plainly about.
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
    /// Only those two: a target class or an interaction id is a machine fact,
    /// and embedding it would teach the index that "media player" is something
    /// a person says when they mean this Skill.
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

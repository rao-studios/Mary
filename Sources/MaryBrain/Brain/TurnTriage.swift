//
//  TurnTriage.swift
//  MaryBrain
//
//  WHAT: THE semantic read of a turn — one pass over the registry's corpus
//        indexes, answering everything the turn body wants to know about what
//        the words mean.
//  IN:   runTurnBody, once, after the routing query is composed
//  OUT:  Verdict — intent, requested abilities, skill affinities, unique pick
//  PIN:  Scores `RoutingQuery.firstLine` ONLY. The composed world/history lines
//        measurably dilute a sentence embedding (a query that wins bare drops
//        below the floor once composed) — see RoutingQuery.swift and the
//        calibration suite that measured it.
//        ABSTAINS, NEVER GUESSES: with no vectorizer every field comes back
//        empty and the turn falls to the model. Nothing here falls back to a
//        word list — that is the whole point of the file.
//
import MaryAmbient
import MaryFoundation
import Foundation

enum TurnTriage {

    /// One turn's worth of semantic answers, taken together so the route, the
    /// roster and the log all quote the same read.
    struct Verdict: Sendable, Equatable {

        /// The embedded intent, among `SemanticIntentIndex.eligibleIntents`.
        /// Nil ONLY when the registry has no intent index — an index that
        /// answers nothing still answers `.converse`, which is the fail-closed
        /// contract the engine's ladder depends on.
        var intent: AmbientIntent?
        var intentScore: Float
        var intentRunnerUp: AmbientIntent?

        /// This turn acts rather than converses. An `EditIntent` ORs in at the
        /// call site — revision is structure, and structure is not this file's.
        var isActionShaped: Bool

        /// Abilities the words ask for, by embedding against their triggers.
        var requestedAbilities: Set<AbilityID>

        /// Every offered Skill's affinity, and the single winner when one
        /// clears the floor with a margin over the runner-up.
        var skillAffinities: [SkillID: Float]
        var uniqueSkill: AbilityRuntimeSkill?

        /// NO INDEX, NO OPINION.
        static let abstained = Verdict(
            intent: nil,
            intentScore: 0,
            intentRunnerUp: nil,
            isActionShaped: false,
            requestedAbilities: [],
            skillAffinities: [:],
            uniqueSkill: nil)

        /// What the log and the trace quote, so both say the same thing.
        var intentDescription: String {
            guard let intent else { return "intent=lexical" }
            let runner = intentRunnerUp?.rawValue ?? "none"
            return "intent=\(intent.rawValue) score=\(String(format: "%.2f", intentScore)) runner=\(runner)"
        }
    }

    /// THE ONE SEMANTIC READ. Pure: every index was built at registry reload,
    /// off the turn path, so this costs one vectorization and one scan.
    ///
    /// `offeredNames` is the invocation names the dispatcher actually exposes
    /// this turn — a Skill the roster withheld must not win a shortcut.
    static func verdict(
        query: String,
        registry: AbilityRuntimeSnapshot,
        offeredNames: Set<String>,
        exemplars: RoutingExemplarStore = .shared
    ) -> Verdict {
        guard let intentIndex = registry.semanticIntentIndex else {
            // The index is the seam. Without it there is no semantic opinion to
            // have, and the caller must not read a `false` here as "not an
            // action" — it is "I cannot say".
            return .abstained
        }
        let classified = intentIndex.classify(query, exemplars: exemplars)
        // FAIL CLOSED. An index that exists but recognizes nothing says
        // `converse`, never nil: nil means "no index at all", and the engine's
        // ladder branches on that difference.
        let intent = classified?.intent ?? .converse

        let affinities = registry.semanticSkillIndex?.affinities(in: query) ?? [:]
        let offered = affinities.filter { id, _ in
            guard let skill = registry.skill(id: id) else { return false }
            return offeredNames.contains(skill.reference.invocationName)
        }

        return Verdict(
            intent: intent,
            intentScore: classified?.score ?? 0,
            intentRunnerUp: classified?.runnerUp,
            isActionShaped: intent == .operate || intent == .compose,
            requestedAbilities: registry.requestedAbilities(in: query),
            skillAffinities: offered,
            uniqueSkill: EmbeddingRouting.uniqueWinner(
                affinities: offered, snapshot: registry))
    }
}

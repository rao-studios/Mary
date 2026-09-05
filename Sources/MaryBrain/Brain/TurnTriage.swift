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

        /// The intent came from the SKILL corpus, not the intent corpus — see
        /// the promotion in `verdict`. Carried so the turn log can say so
        /// rather than reporting an operate verdict the intent index never gave.
        var promotedByUniqueSkill: Bool

        /// NO INDEX, NO OPINION.
        static let abstained = Verdict(
            intent: nil,
            intentScore: 0,
            intentRunnerUp: nil,
            isActionShaped: false,
            requestedAbilities: [],
            skillAffinities: [:],
            uniqueSkill: nil,
            promotedByUniqueSkill: false)

        /// THE SAME READ, AS A VALUE A BENCH CAN RENDER. Everything here was
        /// already computed for the log line below; this is the same facts
        /// crossing out of MaryBrain rather than a second opinion.
        func verdictValue(lane: SemanticTurnLane? = nil) -> SemanticTurnVerdict {
            SemanticTurnVerdict(
                intent: intent?.rawValue,
                intentScore: intentScore,
                intentRunnerUp: intentRunnerUp?.rawValue,
                promotedByUniqueSkill: promotedByUniqueSkill,
                floor: EmbeddingRouting.floor,
                margin: EmbeddingRouting.margin,
                uniqueSkill: uniqueSkill?.reference.invocationName,
                lane: lane)
        }

        /// What the log and the trace quote, so both say the same thing.
        var intentDescription: String {
            guard let intent else { return "intent=lexical" }
            if promotedByUniqueSkill {
                return "intent=\(intent.rawValue) promoted=skill"
            }
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
        registry: AbilityRuntime.Snapshot,
        offeredNames: Set<String>,
        habits: RoutingHabitStore = .shared
    ) -> Verdict {
        guard let intentIndex = registry.semanticIntentIndex else {
            // The index is the seam. Without it there is no semantic opinion to
            // have, and the caller must not read a `false` here as "not an
            // action" — it is "I cannot say".
            return .abstained
        }
        let classified = intentIndex.classify(query, habits: habits)

        // Habits reach BOTH tiers. `classify` took them and `affinities`
        // silently fell back to `.shared`, so an injected store only half
        // applied and the Skill tier could never be tested in isolation.
        let affinities = registry.semanticSkillIndex?
            .affinities(in: query, habits: habits) ?? [:]
        let offered = affinities.filter { id, _ in
            guard let skill = registry.skill(id: id) else { return false }
            return offeredNames.contains(skill.reference.invocationName)
        }

        let uniqueSkill = EmbeddingRouting.uniqueWinner(
            affinities: offered, snapshot: registry)

        // FAIL CLOSED. An index that exists but recognizes nothing says
        // `converse`, never nil: nil means "no index at all", and the engine's
        // ladder branches on that difference.
        //
        // EXCEPT WHEN THE SKILL CORPUS ANSWERED. A fail-closed converse is not
        // a verdict, it is the absence of one — and a turn where exactly one
        // OFFERED Skill cleared the floor with a margin over every rival is the
        // corpus saying, in the only voice it has, that these words are about
        // one act. Believing "converse" there is how the stuck case was made:
        // no dispatch, so no habit, so the intent index never learned the
        // phrasing, forever ("which windows are up right now").
        //
        // A SCORED converse still blocks — this fires only when `classify`
        // returned nil outright. Everything downstream keeps its own gates: the
        // shortcut still needs a dispatchable shape, and a zero-argument verb
        // still needs a whole simple sentence.
        let promoted = classified == nil && uniqueSkill != nil
        let intent = promoted ? .operate : (classified?.intent ?? .converse)

        return Verdict(
            intent: intent,
            intentScore: classified?.score ?? 0,
            intentRunnerUp: classified?.runnerUp,
            isActionShaped: intent == .operate || intent == .compose,
            requestedAbilities: registry.requestedAbilities(in: query),
            skillAffinities: offered,
            uniqueSkill: uniqueSkill,
            promotedByUniqueSkill: promoted)
    }
}

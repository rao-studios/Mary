//
//  AbilityRosterRehearsal.swift
//  MaryBrain
//
//  WHAT: Would this sentence have reached that Skill, with that app in front?
//  IN:   a frozen registry + an utterance + the target classes of a stage
//  OUT:  the real AbilityRosterTrace — dispositions, reasons, election, scores
//  PIN:  THE REAL ARBITRATOR, NOT A MODEL OF IT. Ability Studio's rehearsal ran
//        the embedding tiers alone and stopped there, so it could say a Skill
//        led the corpus and never that it was withheld — for being unready, for
//        a Capability allowlist, or for its whole Ability losing an election it
//        was never told about. Answering "why wasn't it offered" with anything
//        less than the code that decides is how a bench teaches the wrong lesson.
//        WHAT IT CANNOT ANSWER, AND SAYS SO. Two gates need a live turn: the
//        schema signals' mutation authorization, and a workflow's own run state.
//        A rehearsal is honest about being a rehearsal — see `caveat`.
//

import MaryAmbient
import MaryFoundation
import Foundation

public enum AbilityRosterRehearsal {

    /// What a rehearsal cannot decide without a turn, in one sentence for a UI
    /// to print beside its verdict.
    public static let caveat =
        "A rehearsal runs the registry's own gates. What it cannot run is this "
        + "turn's live signals — a selection, a mutation authorization, or a "
        + "workflow already under way."

    /// The roster this sentence would project, with `targetClasses` in view.
    ///
    /// `targetClasses` is what the stage supplies — in a turn they come from the
    /// lead place's registration and every named application; here the caller
    /// names them, which is exactly the "as if Chrome were in front" question.
    public static func trace(
        snapshot: AbilityRuntime.Snapshot,
        utterance: String,
        targetClasses: Set<String> = [],
        namedApplications: Set<String> = [],
        interactions: Set<InteractionID> = [],
        perceptions: Set<PerceptionID> = [],
        habits: RoutingHabitStore = .shared
    ) -> AbilityRosterTrace {
        arbitration(
            snapshot: snapshot, utterance: utterance,
            targetClasses: targetClasses, namedApplications: namedApplications,
            interactions: interactions, perceptions: perceptions,
            habits: habits).trace
    }

    /// The same pass, keeping the selection set for a caller that wants to ask
    /// whether one Skill was offered rather than to render everything.
    static func arbitration(
        snapshot: AbilityRuntime.Snapshot,
        utterance: String,
        targetClasses: Set<String> = [],
        namedApplications: Set<String> = [],
        interactions: Set<InteractionID> = [],
        perceptions: Set<PerceptionID> = [],
        habits: RoutingHabitStore = .shared
    ) -> AbilityRosterArbitration {
        let context = routingContext(
            snapshot: snapshot, utterance: utterance,
            targetClasses: targetClasses, namedApplications: namedApplications,
            interactions: interactions, perceptions: perceptions,
            habits: habits)
        return AbilityRosterArbitrator.arbitrate(
            skills: snapshot.skills,
            context: context,
            baseFailure: { runtime in
                AbilityRuntime.snapshotEligibilityFailure(
                    for: runtime, in: context, snapshot: snapshot)
                    ?? routingFailure(for: runtime, in: context)
            })
    }

    /// The turn's own relevance gate, minus the parts that need a turn.
    ///
    /// PIN: THE SAME TWO BRANCHES `AbilityRuntime.routingEligibilityFailure` HAS,
    /// and it is deliberately not shared with it: that one is an instance method
    /// reaching for a live world, and forcing this through it would mean giving a
    /// rehearsal a fake runtime. The sentences are kept identical so a bench and
    /// a turn never disagree about the words.
    private static func routingFailure(
        for runtime: AbilityRuntimeSkill,
        in context: AbilityRoutingContext
    ) -> String? {
        if context.usesEmbeddingRoster {
            guard context.semanticSkillAffinity[runtime.skill.id] != nil else {
                return "does not match this turn's embedding roster"
            }
            return nil
        }
        if !AbilityRoutingEvaluator.isEligible(runtime.ability.routing, in: context),
           !context.requestedAbilities.contains(runtime.ability.id) {
            return "does not match its Ability-level routing policy"
        }
        if !AbilityRoutingEvaluator.isEligible(runtime.skill.routing, in: context) {
            return "does not match this turn's source and routing context"
        }
        return nil
    }

    /// What a turn would have assembled, from what a stage can state.
    ///
    /// The Capability set mirrors `AbilityRuntime.abilityRoutingContext`: a
    /// Skill requiring a Capability nothing installed publishes is unreachable
    /// whatever the words say, and leaving it empty would report every such
    /// Skill as a routing miss rather than an installation one.
    static func routingContext(
        snapshot: AbilityRuntime.Snapshot,
        utterance: String,
        targetClasses: Set<String>,
        namedApplications: Set<String>,
        interactions: Set<InteractionID> = [],
        perceptions: Set<PerceptionID> = [],
        habits: RoutingHabitStore = .shared
    ) -> AbilityRoutingContext {
        let scored = snapshot.semanticSkillIndex?
            .affinities(in: utterance, habits: habits, floor: 0) ?? [:]
        let capabilities = Set(
            snapshot.bindings
                .filter { $0.adapter.isAvailable }
                .flatMap { $0.adapter.capabilities })
        let grantedPermissions = Set(
            snapshot.adapterManifests
                .filter(\.isAvailable)
                .flatMap(\.grantedPermissions))
        return AbilityRoutingContext(
            utterance: utterance,
            namedApplications: namedApplications,
            targetClasses: targetClasses,
            interactions: interactions,
            // Evidence rank 1 = "present, unranked". A rehearsal is told THAT a
            // selection stands, never how strong the evidence for it was.
            interactionEvidenceRanks: Dictionary(
                interactions.map { ($0, 1) }, uniquingKeysWith: { first, _ in first }),
            perceptions: perceptions,
            capabilities: capabilities,
            grantedPermissions: grantedPermissions,
            semanticSkillAffinity: scored.filter {
                $0.value >= SemanticSkillRequestIndex.defaultThreshold
            },
            semanticSkillScores: scored,
            usesEmbeddingRoster: snapshot.semanticSkillIndex != nil,
            requestedAbilities: snapshot.semanticSkillIndex == nil
                ? snapshot.requestedAbilities(in: utterance) : [])
    }
}

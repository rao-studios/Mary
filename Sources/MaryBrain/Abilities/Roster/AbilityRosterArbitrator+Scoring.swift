//
//  AbilityRosterArbitrator+Scoring.swift
//  MaryBrain
//
//  WHAT: Additive scoring pass for roster arbitration.
//  IN:   AbilityRosterArbitrator.swift
//  OUT:  bounded score deltas
//  PIN:  Additive, bounded, last — never a veto.
//
import MaryFoundation
import Foundation

extension AbilityRosterArbitrator {

    static func decision(
        _ runtime: AbilityRuntimeSkill,
        disposition: AbilityRosterDisposition,
        score: AbilityRoutingEvidenceScore,
        selectedAlternative: AbilitySkillReference? = nil,
        fallbackFor: AbilitySkillReference? = nil,
        reason: String
    ) -> AbilityRosterDecision {
        AbilityRosterDecision(
            key: AbilityRosterSkillKey(runtime),
            reference: runtime.reference,
            conflictGroup: normalizedGroup(runtime.skill.routing.conflictGroup),
            policy: runtime.skill.routing.conflictPolicy,
            disposition: disposition,
            evidence: score,
            selectedAlternative: selectedAlternative,
            fallbackFor: fallbackFor,
            reason: reason)
    }

    static func evidence(
        policy: RoutingPolicySchema,
        requirements: SkillRequirements?,
        context: AbilityRoutingContext,
        skillID: SkillID? = nil
    ) -> AbilityRoutingEvidenceScore {
        let directIDs = Set(requirements?.interactions ?? [])
            .union(requirements?.optionalInteractions ?? [])
            .union(policy.eligibility.map {
                positiveInteractionIDs(in: $0, context: context)
            } ?? [])
        let direct = directIDs.reduce(0) { partial, id in
            partial + min(max(context.interactionEvidenceRanks[id] ?? 1, 1), 10_000)
        }
        let predicateEvidence = policy.eligibility.map {
            predicateScore($0, context: context)
        } ?? 0
        let perceptionEvidence = (requirements?.perceptions ?? []).reduce(0) {
            $0 + (context.perceptions.contains($1) ? 40 : 0)
        }
        let optionalPerceptionEvidence = (requirements?.optionalPerceptions ?? []).reduce(0) {
            $0 + (context.perceptions.contains($1) ? 15 : 0)
        }
        let capabilityEvidence = (requirements?.capabilities ?? []).reduce(0) {
            $0 + (context.capabilities.contains($1) ? 5 : 0)
        }
        let focused = focusedWorkspaceScore(
            policy: policy,
            requirements: requirements,
            context: context)
        // Affinity is the score when embeddings pick the roster.
        let semanticEvidence: Int
        if context.usesEmbeddingRoster,
           let skillID,
           let affinity = context.semanticSkillAffinity[skillID] {
            semanticEvidence = Int((affinity * 1000).rounded())
            return AbilityRoutingEvidenceScore(
                total: semanticEvidence,
                directInteraction: direct,
                focusedWorkspace: focused,
                preference: policy.preference)
        }
        semanticEvidence = skillID
            .flatMap { context.semanticSkillAffinity[$0] }
            .map { SemanticSkillRequestIndex.bonus(for: $0) } ?? 0
        return AbilityRoutingEvidenceScore(
            total: predicateEvidence
                + perceptionEvidence
                + optionalPerceptionEvidence
                + capabilityEvidence
                + direct
                + semanticEvidence,
            directInteraction: direct,
            focusedWorkspace: focused,
            preference: policy.preference)
    }

    static func resolvedPolicy(
        _ policies: [RoutingConflictPolicy],
        scores: [AbilityRoutingEvidenceScore]
    ) -> RoutingConflictPolicy {
        // Ambiguity policies are hard conservative boundaries. The two
        // preference policies engage only when the typed evidence they name is
        // actually present; otherwise they degrade to highest-evidence.
        if policies.contains(.abstain) { return .abstain }
        if policies.contains(.askUser) { return .askUser }
        if policies.contains(.preferDirectInteraction),
           scores.contains(where: { $0.directInteraction > 0 }) {
            return .preferDirectInteraction
        }
        if policies.contains(.preferFocusedWorkspace),
           scores.contains(where: { $0.focusedWorkspace > 0 }) {
            return .preferFocusedWorkspace
        }
        return .highestEvidence
    }

    static func ranksBefore(
        _ lhs: (AbilityRoutingEvidenceScore, String),
        _ rhs: (AbilityRoutingEvidenceScore, String),
        policy: RoutingConflictPolicy
    ) -> Bool {
        let left = rankVector(lhs.0, policy: policy)
        let right = rankVector(rhs.0, policy: policy)
        if left != right {
            for index in left.indices where left[index] != right[index] {
                return left[index] > right[index]
            }
        }
        return lhs.1 < rhs.1
    }

    static func rankVector(
        _ score: AbilityRoutingEvidenceScore,
        policy: RoutingConflictPolicy
    ) -> [Int] {
        switch policy {
        case .preferDirectInteraction:
            return [
                score.directInteraction, score.total,
                score.focusedWorkspace,
            ]
        case .preferFocusedWorkspace:
            return [
                score.focusedWorkspace, score.total,
                score.directInteraction,
            ]
        case .highestEvidence, .askUser, .abstain:
            return [
                score.total, score.directInteraction,
                score.focusedWorkspace,
            ]
        }
    }

    static func predicateScore(
        _ predicate: RoutingPredicate,
        context: AbilityRoutingContext
    ) -> Int {
        guard AbilityRoutingEvaluator.evaluate(predicate, in: context) else { return 0 }
        switch predicate.kind {
        case .all:
            return predicate.children.reduce(0) {
                $0 + predicateScore($1, context: context)
            }
        case .any:
            return predicate.children.map {
                predicateScore($0, context: context)
            }.max() ?? 0
        case .not:
            return 1
        case .intent:
            return 100
        case .utteranceToken:
            return 30
        case .utterancePhrase:
            return 50
        case .namedApplication:
            return 70
        case .targetClass:
            return 70
        case .hasInteraction:
            guard let value = predicate.value else { return 0 }
            let rank = context.interactionEvidenceRanks[InteractionID(value)] ?? 1
            return 120 + min(max(rank, 1), 10_000)
        case .hasPerception:
            return 80
        case .hasCapability, .permissionGranted:
            return 20
        case .sourceResolution:
            return 30 + sourceRank(context.sourceResolution)
        case .workspaceFamily:
            return 100
        }
    }

    static func positiveInteractionIDs(
        in predicate: RoutingPredicate,
        context: AbilityRoutingContext
    ) -> Set<InteractionID> {
        guard AbilityRoutingEvaluator.evaluate(predicate, in: context) else { return [] }
        switch predicate.kind {
        case .hasInteraction:
            return predicate.value.map { [InteractionID($0)] } ?? []
        case .all:
            return predicate.children.reduce(into: Set<InteractionID>()) {
                $0.formUnion(positiveInteractionIDs(in: $1, context: context))
            }
        case .any:
            let matched = predicate.children.filter {
                AbilityRoutingEvaluator.evaluate($0, in: context)
            }
            let highest = matched.map {
                ($0, predicateScore($0, context: context))
            }.max { $0.1 < $1.1 }?.0
            return highest.map {
                positiveInteractionIDs(in: $0, context: context)
            } ?? []
        case .not:
            return []
        default:
            return []
        }
    }

    static func focusedWorkspaceScore(
        policy: RoutingPolicySchema,
        requirements: SkillRequirements?,
        context: AbilityRoutingContext
    ) -> Int {
        var result = 0
        if let minimum = policy.requiredSourceResolution,
           sourceRank(minimum) >= sourceRank(.workspace),
           sourceRank(context.sourceResolution) >= sourceRank(minimum) {
            result += 200 + sourceRank(context.sourceResolution)
        }
        if let predicate = policy.eligibility {
            result += workspacePredicateScore(predicate, context: context)
        }
        let workspacePerceptions: Set<PerceptionID> = [
            .workspaceFocus, .codeWorkspaceFocus, .projectFocus,
        ]
        for perception in requirements?.perceptions ?? []
        where workspacePerceptions.contains(perception)
            && context.perceptions.contains(perception) {
            result += 300
        }
        for perception in requirements?.optionalPerceptions ?? []
        where workspacePerceptions.contains(perception)
            && context.perceptions.contains(perception) {
            result += 100
        }
        return result
    }

    static func workspacePredicateScore(
        _ predicate: RoutingPredicate,
        context: AbilityRoutingContext
    ) -> Int {
        guard AbilityRoutingEvaluator.evaluate(predicate, in: context) else { return 0 }
        switch predicate.kind {
        case .workspaceFamily:
            return 400
        case .targetClass:
            guard let value = predicate.value?.lowercased() else { return 0 }
            return value.contains("workspace") ? 250 : 0
        case .sourceResolution:
            return sourceRank(context.sourceResolution) >= sourceRank(.workspace) ? 200 : 0
        case .all:
            return predicate.children.reduce(0) {
                $0 + workspacePredicateScore($1, context: context)
            }
        case .any:
            return predicate.children.map {
                workspacePredicateScore($0, context: context)
            }.max() ?? 0
        case .not, .intent, .utteranceToken, .utterancePhrase,
             .namedApplication, .hasInteraction, .hasPerception,
             .hasCapability, .permissionGranted:
            return 0
        }
    }

    static func sourceRank(_ value: SourceResolution) -> Int {
        switch value {
        case .unresolved: return 0
        case .device: return 1
        case .application: return 2
        case .window: return 3
        case .workspace: return 4
        case .document: return 5
        }
    }

    static func normalizedGroup(_ value: String?) -> String? {
        guard let group = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !group.isEmpty
        else { return nil }
        return group
    }

    static func stableOrder(
        _ lhs: AbilityRuntimeSkill,
        _ rhs: AbilityRuntimeSkill
    ) -> Bool {
        stableOrder(lhs.reference, rhs.reference)
    }

    /// Stable order WITHOUT moving the elements. Swift's `sorted` shuffles
    /// whole values, and both the runtime skills and the decisions sorted here
    /// are large structs whose every move is a run of retain/release traffic —
    /// the single most expensive thing the arbitrator did. Ordering the
    /// indices and materializing once is the same sequence for a fraction of
    /// the work.
    static func orderedStably<Element>(
        _ elements: [Element],
        by reference: (Element) -> AbilitySkillReference
    ) -> [Element] {
        guard elements.count > 1 else { return elements }
        let references = elements.map(reference)
        let order = elements.indices.sorted {
            stableOrder(references[$0], references[$1])
        }
        return order.map { elements[$0] }
    }

    static func orderedStably(_ skills: [AbilityRuntimeSkill]) -> [AbilityRuntimeSkill] {
        orderedStably(skills, by: \.reference)
    }

    static func stableOrder(
        _ lhs: AbilitySkillReference,
        _ rhs: AbilitySkillReference
    ) -> Bool {
        if lhs.packageID.rawValue != rhs.packageID.rawValue {
            return lhs.packageID.rawValue < rhs.packageID.rawValue
        }
        if lhs.abilityID.rawValue != rhs.abilityID.rawValue {
            return lhs.abilityID.rawValue < rhs.abilityID.rawValue
        }
        return lhs.skillID.rawValue < rhs.skillID.rawValue
    }

}

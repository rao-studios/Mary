//
//  AbilityRoutingEvaluator.swift
//  MaryBrain
//
//  WHAT: Embedding similarity between utterance and each Skill's trigger corpus.
//  IN:   SemanticSkillRequestIndex
//  OUT:  affinities for scoring
//
import Foundation

/// Facts the closed routing predicate language is allowed to inspect. This is
/// deliberately data-only: a shared package can tune eligibility and ordering,
/// but it cannot inject code or bypass Mary's confirmation/stage policies.
public struct AbilityRoutingContext: Sendable, Equatable {
    public var utterance: String
    public var intent: String?
    public var namedApplications: Set<String>
    public var targetClasses: Set<String>
    public var interactions: Set<InteractionID>
    /// Highest schema-validated evidence rank for each current Interaction.
    /// The payload remains in the Interaction runtime; roster arbitration sees
    /// only this bounded machine fact.
    public var interactionEvidenceRanks: [InteractionID: Int]
    public var perceptions: Set<PerceptionID>
    public var capabilities: Set<CapabilityID>
    public var grantedPermissions: Set<PermissionKind>
    public var sourceResolution: SourceResolution
    public var workspaceFamily: String?
    /// Embedding similarity between this turn's utterance and each Skill's authored corpus.
    public var semanticSkillAffinity: [SkillID: Float]

    public init(
        utterance: String = "",
        intent: String? = nil,
        namedApplications: Set<String> = [],
        targetClasses: Set<String> = [],
        interactions: Set<InteractionID> = [],
        interactionEvidenceRanks: [InteractionID: Int] = [:],
        perceptions: Set<PerceptionID> = [],
        capabilities: Set<CapabilityID> = [],
        grantedPermissions: Set<PermissionKind> = [],
        sourceResolution: SourceResolution = .unresolved,
        workspaceFamily: String? = nil,
        semanticSkillAffinity: [SkillID: Float] = [:]
    ) {
        self.utterance = utterance
        self.intent = intent
        self.namedApplications = namedApplications
        self.targetClasses = targetClasses
        self.interactions = interactions
        self.interactionEvidenceRanks = interactionEvidenceRanks
        self.perceptions = perceptions
        self.capabilities = capabilities
        self.grantedPermissions = grantedPermissions
        self.sourceResolution = sourceResolution
        self.workspaceFamily = workspaceFamily
        self.semanticSkillAffinity = semanticSkillAffinity
    }
}

public enum AbilityRoutingEvaluator {
    public static func isEligible(
        _ policy: RoutingPolicySchema,
        in context: AbilityRoutingContext
    ) -> Bool {
        if let minimum = policy.requiredSourceResolution,
           rank(context.sourceResolution) < rank(minimum) {
            return false
        }
        if policy.excludes.contains(where: { evaluate($0, in: context) }) {
            return false
        }
        return policy.eligibility.map { evaluate($0, in: context) } ?? true
    }

    public static func evaluate(
        _ predicate: RoutingPredicate,
        in context: AbilityRoutingContext
    ) -> Bool {
        let value = predicate.value?.lowercased()
        switch predicate.kind {
        case .all:
            return predicate.children.allSatisfy { evaluate($0, in: context) }
        case .any:
            return predicate.children.contains { evaluate($0, in: context) }
        case .not:
            guard predicate.children.count == 1 else { return false }
            return !evaluate(predicate.children[0], in: context)
        case .intent:
            return value != nil && context.intent?.lowercased() == value
        case .utteranceToken:
            guard let value else { return false }
            return words(in: context.utterance).contains(value)
        case .utterancePhrase:
            guard let value else { return false }
            return context.utterance.lowercased().contains(value)
        case .namedApplication:
            return value != nil && context.namedApplications.map { $0.lowercased() }.contains(value!)
        case .targetClass:
            return value != nil && context.targetClasses.map { $0.lowercased() }.contains(value!)
        case .hasInteraction:
            return value != nil && context.interactions.contains(InteractionID(value!))
        case .hasPerception:
            return value != nil && context.perceptions.contains(PerceptionID(value!))
        case .hasCapability:
            return value != nil && context.capabilities.contains(CapabilityID(value!))
        case .permissionGranted:
            return value.flatMap(PermissionKind.init(rawValue:))
                .map(context.grantedPermissions.contains) ?? false
        case .sourceResolution:
            return value.flatMap(SourceResolution.init(rawValue:)) == context.sourceResolution
        case .workspaceFamily:
            return value != nil && context.workspaceFamily?.lowercased() == value
        }
    }

    private static func words(in value: String) -> Set<String> {
        Set(value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))
    }

    private static func rank(_ value: SourceResolution) -> Int {
        switch value {
        case .unresolved: return 0
        case .device: return 1
        case .application: return 2
        case .window: return 3
        case .workspace: return 4
        case .document: return 5
        }
    }
}

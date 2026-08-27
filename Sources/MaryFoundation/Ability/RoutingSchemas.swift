import Foundation

/// A closed predicate language. Ability packages may contribute data to the
/// router, but cannot ship code or replace Mary's safety arbitration.
public struct RoutingPredicate: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case all
        case any
        case not
        case intent
        case utteranceToken
        case utterancePhrase
        case namedApplication
        case targetClass
        case hasInteraction
        case hasPerception
        case hasCapability
        case permissionGranted
        case sourceResolution
        case workspaceFamily
    }

    public var kind: Kind
    public var value: String?
    public var children: [RoutingPredicate]

    public init(kind: Kind, value: String? = nil, children: [RoutingPredicate] = []) {
        self.kind = kind
        self.value = value
        self.children = children
    }
}

public enum RoutingConflictPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case highestEvidence
    case preferDirectInteraction
    case preferFocusedWorkspace
    case askUser
    case abstain
}

public struct RoutingPolicySchema: Codable, Hashable, Sendable {
    public var eligibility: RoutingPredicate?
    public var preference: Int
    public var conflictGroup: String?
    public var conflictPolicy: RoutingConflictPolicy
    public var fallbacks: [SkillID]
    public var excludes: [RoutingPredicate]
    public var requiredSourceResolution: SourceResolution?

    public init(
        eligibility: RoutingPredicate? = nil,
        preference: Int = 0,
        conflictGroup: String? = nil,
        conflictPolicy: RoutingConflictPolicy = .highestEvidence,
        fallbacks: [SkillID] = [],
        excludes: [RoutingPredicate] = [],
        requiredSourceResolution: SourceResolution? = nil
    ) {
        self.eligibility = eligibility
        self.preference = preference
        self.conflictGroup = conflictGroup
        self.conflictPolicy = conflictPolicy
        self.fallbacks = fallbacks
        self.excludes = excludes
        self.requiredSourceResolution = requiredSourceResolution
    }
}

public struct AbilityTriggerSchema: Codable, Hashable, Sendable {
    public var tokens: [String]
    public var phrases: [String]
    public var negativeTokens: [String]
    public var intentAliases: [String]

    public init(
        tokens: [String] = [],
        phrases: [String] = [],
        negativeTokens: [String] = [],
        intentAliases: [String] = []
    ) {
        self.tokens = tokens
        self.phrases = phrases
        self.negativeTokens = negativeTokens
        self.intentAliases = intentAliases
    }
}

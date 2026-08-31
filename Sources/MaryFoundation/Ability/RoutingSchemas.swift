//
//  RoutingSchemas.swift
//  MaryFoundation
//
//  WHAT: Closed routing predicates and conflict policy.
//  IN:   AbilitySchema.routing / SkillSchema.routing.
//  OUT:  MaryBrain route, AbilityPackageValidator predicate checks.
//  PIN:  Packages contribute data, never code or safety arbitration.
//

import Foundation

/// Closed predicate language.
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
    /// Authored sentences for `SemanticIntentIndex`, keyed by `AmbientIntent.rawValue`
    /// ("operate", "perceive", "compose", "ask", "converse"). MaryFoundation cannot
    /// see `AmbientIntent` — the key is validated where it is consumed.
    public var intentExemplars: [String: [String]]

    public init(
        tokens: [String] = [],
        phrases: [String] = [],
        negativeTokens: [String] = [],
        intentAliases: [String] = [],
        intentExemplars: [String: [String]] = [:]
    ) {
        self.tokens = tokens
        self.phrases = phrases
        self.negativeTokens = negativeTokens
        self.intentAliases = intentAliases
        self.intentExemplars = intentExemplars
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, phrases, negativeTokens, intentAliases, intentExemplars
    }

    /// Tolerant decode — a package sealed before this field existed must
    /// still load. Every field decodes with a default, not only the new one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decodeIfPresent([String].self, forKey: .tokens) ?? []
        phrases = try container.decodeIfPresent([String].self, forKey: .phrases) ?? []
        negativeTokens = try container.decodeIfPresent(
            [String].self, forKey: .negativeTokens) ?? []
        intentAliases = try container.decodeIfPresent(
            [String].self, forKey: .intentAliases) ?? []
        intentExemplars = try container.decodeIfPresent(
            [String: [String]].self, forKey: .intentExemplars) ?? [:]
    }
}

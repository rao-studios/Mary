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
    ///
    /// SEEDS, NOT HABITS. These are authored once and frozen until the author
    /// edits them; a habit is learned from use and decays. The intent index
    /// takes both — these as its corpus, `RoutingHabitStore` on top — so the
    /// two must not share a word. `seedFamilies` below is the same kind of
    /// thing for families rather than intents.
    public var intentSeeds: [String: [String]]

    /// Authored sentences for named SEED FAMILIES — the shapes of speech that
    /// are not an intent and not a Skill, but that the turn body still has to
    /// recognize ("does this sentence ask for a transformation?").
    ///
    /// A GENERIC MAP ON PURPOSE. Every family that used to be a verb list in
    /// Swift becomes a key here, so the next one needs authored sentences
    /// rather than a schema change. Keys are validated where they are consumed
    /// — MaryFoundation must not learn what families the Brain knows.
    public var seedFamilies: [String: [String]]

    public init(
        tokens: [String] = [],
        phrases: [String] = [],
        negativeTokens: [String] = [],
        intentAliases: [String] = [],
        intentSeeds: [String: [String]] = [:],
        seedFamilies: [String: [String]] = [:]
    ) {
        self.tokens = tokens
        self.phrases = phrases
        self.negativeTokens = negativeTokens
        self.intentAliases = intentAliases
        self.intentSeeds = intentSeeds
        self.seedFamilies = seedFamilies
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, phrases, negativeTokens, intentAliases, intentSeeds
        case seedFamilies
        /// RETIRED SPELLING, STILL READ. `intentSeeds` was `intentExemplars`
        /// until the routing vocabulary was split into authored seeds and
        /// learned habits. This decodes tolerantly and does NOT reject unknown
        /// keys, so dropping the old name would leave a package sealed before
        /// the rename with an EMPTY intent corpus and no error to show for it —
        /// intent classification would quietly stop working for that package.
        case intentExemplars
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
        // New spelling wins; the retired one answers for packages sealed
        // before the rename.
        intentSeeds = try container.decodeIfPresent(
            [String: [String]].self, forKey: .intentSeeds)
            ?? container.decodeIfPresent(
                [String: [String]].self, forKey: .intentExemplars)
            ?? [:]
        seedFamilies = try container.decodeIfPresent(
            [String: [String]].self, forKey: .seedFamilies) ?? [:]
    }

    /// READ THE OLD SPELLING, WRITE ONLY THE NEW ONE. Encoding is explicit
    /// because `CodingKeys` carries a retired case with no property behind it,
    /// which nothing can synthesize. It also makes resealing a migration: a
    /// package loaded with `intentExemplars` is written back as `intentSeeds`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(phrases, forKey: .phrases)
        try container.encode(negativeTokens, forKey: .negativeTokens)
        try container.encode(intentAliases, forKey: .intentAliases)
        try container.encode(intentSeeds, forKey: .intentSeeds)
        try container.encode(seedFamilies, forKey: .seedFamilies)
    }
}

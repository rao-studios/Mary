//
//  InteractionSchemas.swift
//  MaryFoundation
//
//  WHAT: Interaction ownership, claim/clear policy, evidence, schema.
//  IN:   `.mary` interactions[] → AbilityPackageValidator+Schemas.
//  OUT:  Ambient capture, SkillRequirements.
//

import Foundation

public enum InteractionOwnership: String, Codable, Hashable, Sendable, CaseIterable {
    case sourceOwned
    case deviceOwned
    case systemOwned
}

public enum InteractionClaimPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// One turn consumes the instance.
    case oneTurn
    /// Reusable until expiry or supersession.
    case reusable
}

public enum InteractionClearPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case explicitSourceEvent
    case sourceTermination
    case expiry
    case replacement
}

public struct InteractionEvidenceRule: Codable, Hashable, Sendable {
    public var channel: String
    public var rank: Int
    public var canAuthorizeMutation: Bool

    public init(channel: String, rank: Int, canAuthorizeMutation: Bool) {
        self.channel = channel
        self.rank = rank
        self.canAuthorizeMutation = canAuthorizeMutation
    }
}

public struct InteractionSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: InteractionID
    public var version: SemanticVersion
    public var title: String
    public var summary: String
    public var valueType: ValueTypeID
    public var ownership: InteractionOwnership
    public var claimPolicy: InteractionClaimPolicy
    public var freshnessSeconds: Double
    public var supersessionKeys: [String]
    public var clearPolicies: [InteractionClearPolicy]
    public var evidence: [InteractionEvidenceRule]
    public var requiredScope: [SourceResolution]
    public var privacy: DataPrivacyClass
    public var totemProjection: ProjectionID?

    public init(
        id: InteractionID,
        version: SemanticVersion = "1.0.0",
        title: String,
        summary: String,
        valueType: ValueTypeID,
        ownership: InteractionOwnership,
        claimPolicy: InteractionClaimPolicy,
        freshnessSeconds: Double,
        supersessionKeys: [String],
        clearPolicies: [InteractionClearPolicy],
        evidence: [InteractionEvidenceRule],
        requiredScope: [SourceResolution] = [.application],
        privacy: DataPrivacyClass = .sensitive,
        totemProjection: ProjectionID? = nil
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.valueType = valueType
        self.ownership = ownership
        self.claimPolicy = claimPolicy
        self.freshnessSeconds = freshnessSeconds
        self.supersessionKeys = supersessionKeys
        self.clearPolicies = clearPolicies
        self.evidence = evidence
        self.requiredScope = requiredScope
        self.privacy = privacy
        self.totemProjection = totemProjection
    }
}

public enum PerceptionOwnership: String, Codable, Hashable, Sendable, CaseIterable {
    case observed
    case inferred
    case userAsserted
}

public struct PerceptionSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: PerceptionID
    public var version: SemanticVersion
    public var title: String
    public var summary: String
    public var valueType: ValueTypeID
    public var ownership: PerceptionOwnership
    public var freshnessSeconds: Double
    public var privacy: DataPrivacyClass

    public init(
        id: PerceptionID,
        version: SemanticVersion = "1.0.0",
        title: String,
        summary: String,
        valueType: ValueTypeID,
        ownership: PerceptionOwnership = .observed,
        freshnessSeconds: Double,
        privacy: DataPrivacyClass = .`private`
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.valueType = valueType
        self.ownership = ownership
        self.freshnessSeconds = freshnessSeconds
        self.privacy = privacy
    }
}

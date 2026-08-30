//
//  TotemProjectionSchema.swift
//  MaryFoundation
//
//  WHAT: Which Skill/Interaction fields may persist, and for how long.
//  IN:   `.mary` totemProjections[] → AbilityPackageValidator+Schemas.
//  OUT:  Ability Totem (this Ability + extended disciplines).
//

import Foundation

public enum TotemLane: String, Codable, Hashable, Sendable, CaseIterable {
    case ability
    case personal
}

/// Ability Totem address: one Ability, one role.
public struct AbilityTotemTarget: Codable, Hashable, Sendable, Comparable {
    public var abilityID: AbilityID
    public var paradigm: AbilityParadigm

    public init(abilityID: AbilityID, paradigm: AbilityParadigm) {
        self.abilityID = abilityID
        self.paradigm = paradigm
    }

    public var label: String {
        "\(abilityID.rawValue) · \(paradigm.label)"
    }

    public static func < (lhs: AbilityTotemTarget, rhs: AbilityTotemTarget) -> Bool {
        if lhs.abilityID.rawValue != rhs.abilityID.rawValue {
            return lhs.abilityID.rawValue < rhs.abilityID.rawValue
        }
        return lhs.paradigm.rawValue < rhs.paradigm.rawValue
    }
}

public enum ProjectionPersistence: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case session
    case durable
}

/// Machine job of a Totem projection. Closed so content cannot collapse into a redacted receipt.
public enum TotemProjectionPurpose: String, Codable, Hashable, Sendable, CaseIterable {
    case receipt
    case content
    case interaction
}

public struct TotemProjectionSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectionID
    public var version: SemanticVersion
    public var purpose: TotemProjectionPurpose
    /// Skills this projection applies to. Empty = every Skill; Interaction must stay empty.
    public var skills: [SkillID]
    public var persistence: ProjectionPersistence
    public var include: [String]
    public var exclude: [String]
    public var redactContent: Bool
    public var retentionSeconds: Double?

    public init(
        id: ProjectionID,
        version: SemanticVersion = "1.0.0",
        purpose: TotemProjectionPurpose,
        skills: [SkillID] = [],
        persistence: ProjectionPersistence,
        include: [String] = [],
        exclude: [String] = [],
        redactContent: Bool = true,
        retentionSeconds: Double? = nil
    ) {
        self.id = id
        self.version = version
        self.purpose = purpose
        self.skills = skills
        self.persistence = persistence
        self.include = include
        self.exclude = exclude
        self.redactContent = redactContent
        self.retentionSeconds = retentionSeconds
    }
}

//
//  TotemProjectionSchema.swift
//  MaryFoundation
//
//  WHAT AN ABILITY IS ALLOWED TO REMEMBER. A projection declares which fields
//  of a Skill result or Interaction may persist, and for how long — memory as
//  a declaration rather than a side effect. Where that memory lands is not
//  authored: durable projections file to Ability Totem for this Ability, and
//  application expertise also indexes the disciplines it extends.
//

import Foundation

public enum TotemLane: String, Codable, Hashable, Sendable, CaseIterable {
    case ability
    case personal
}

/// Where an Ability Totem group is addressed: one Ability, in one role.
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

/// The machine-level job performed by a Totem projection.
///
/// Receipt projections retain execution facts, content projections retain an
/// explicitly selected subset of the Skill's arguments, and Interaction
/// projections govern source-owned transient signals. Keeping these purposes
/// closed prevents a content schema from being silently collapsed into a
/// redacted receipt merely because both belong to the same Ability.
public enum TotemProjectionPurpose: String, Codable, Hashable, Sendable, CaseIterable {
    case receipt
    case content
    case interaction
}

public struct TotemProjectionSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectionID
    public var version: SemanticVersion
    public var purpose: TotemProjectionPurpose
    /// Skills this projection applies to. Empty means every Skill exported by
    /// the owning Ability; Interaction projections must leave this empty.
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

//
//  TotemProjectionSchema.swift
//  MaryFoundation
//
//  WHAT AN ABILITY IS ALLOWED TO REMEMBER. A projection declares which fields
//  of a Skill result or Interaction may persist, into which lane, and for how
//  long — memory as a declaration rather than a side effect.
//

import Foundation

public enum TotemLane: String, Codable, Hashable, Sendable, CaseIterable {
    case application
    case personal
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
    public var lanes: [TotemLane]
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
        lanes: [TotemLane],
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
        self.lanes = lanes
        self.persistence = persistence
        self.include = include
        self.exclude = exclude
        self.redactContent = redactContent
        self.retentionSeconds = retentionSeconds
    }
}

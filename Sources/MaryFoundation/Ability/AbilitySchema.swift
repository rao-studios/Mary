//
//  AbilitySchema.swift
//  MaryFoundation
//
//  THE ABILITY ITSELF: how it presents, how it routes, what it may do while
//  it holds a turn, and which Skills and projections it exports.
//

import Foundation

/// Human-readable annotations for Ability Studio and documentation. These
/// strings never carry model instruction authority. Executable policy lives
/// in closed routing predicates, Skill access/effect contracts, cognitive
/// primitive identities, and validated workflow topology.
public struct AbilityOperatingPolicy: Codable, Hashable, Sendable {
    public var phases: [String]
    public var guardrails: [String]
    public var successSignals: [String]
    public var stopConditions: [String]
    public var defaultSupportingAbilities: [AbilityID]

    public init(
        phases: [String] = [],
        guardrails: [String] = [],
        successSignals: [String] = [],
        stopConditions: [String] = [],
        defaultSupportingAbilities: [AbilityID] = []
    ) {
        self.phases = phases
        self.guardrails = guardrails
        self.successSignals = successSignals
        self.stopConditions = stopConditions
        self.defaultSupportingAbilities = defaultSupportingAbilities
    }
}

public struct AbilitySchema: Codable, Hashable, Sendable, Identifiable {
    public var id: AbilityID
    public var version: SemanticVersion
    public var title: String
    /// Inspector metadata. The prompt compiler never interpolates this text.
    public var summary: String
    public var tint: String
    public var aliases: [String]
    public var triggers: AbilityTriggerSchema
    public var skills: [SkillID]
    public var operatingPolicy: AbilityOperatingPolicy
    public var routing: RoutingPolicySchema
    public var totemProjections: [ProjectionID]
    /// WHAT KIND OF ABILITY THIS IS — see `AbilityParadigm`. Optional so that
    /// every package written before the field existed still decodes; read it
    /// through `MaryAbilityPackage.paradigm`, which falls back to a
    /// structural derivation rather than leaving callers to handle nil.
    public var paradigm: AbilityParadigm?
    /// The applications this Ability is expert in, for an Ability that is not
    /// a Plugin-bearing package. Nil (not empty) means "says nothing", which
    /// for a Plugin-bearing Ability is correct — its plugin already answers.
    public var applications: [ApplicationAffinity]?

    public init(
        id: AbilityID,
        version: SemanticVersion = "1.0.0",
        title: String,
        summary: String,
        tint: String,
        aliases: [String] = [],
        triggers: AbilityTriggerSchema = .init(),
        skills: [SkillID],
        operatingPolicy: AbilityOperatingPolicy = .init(),
        routing: RoutingPolicySchema = .init(),
        totemProjections: [ProjectionID] = [],
        paradigm: AbilityParadigm? = nil,
        applications: [ApplicationAffinity]? = nil
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.tint = tint
        self.aliases = aliases
        self.triggers = triggers
        self.skills = skills
        self.operatingPolicy = operatingPolicy
        self.routing = routing
        self.totemProjections = totemProjections
        self.paradigm = paradigm
        self.applications = applications
    }
}

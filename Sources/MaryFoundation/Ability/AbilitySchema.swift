//
//  AbilitySchema.swift
//  MaryFoundation
//
//  WHAT: Ability presentation, routing, operating policy, exported skills.
//  IN:   `.mary` ability block → AbilityPackageValidator.
//  OUT:  AbilityPromptProjection, AbilityRuntime, MaryAbilityPackage.paradigm.
//

import Foundation

/// Closed caution categories for AbilityOperatingPolicy and PluginOperationSchema.caution.
/// OUT: AbilityPromptProjection.render / AbilityRuntime.projectedBindingDescription.
public enum GuardrailCategory: String, Codable, Hashable, Sendable, CaseIterable {
    /// Wrong surface kind — e.g. never type prose into a code surface.
    case domainMismatch
    /// Only the named or focused target, never an inferred neighbor.
    case unscopedTarget
    /// Read live state; never answer from memory.
    case staleState
    /// Never bring the target forward merely to observe or command it.
    case noFocusSteal
    /// Use the app's own command, never synthesized input standing in.
    case nativeCommandOnly
    /// Can destroy/replace content; confirm the exact fresh target.
    case irreversibleAction
}

/// Studio/docs annotations. Never model-instruction authority.
/// Executable policy: routing predicates, Skill contracts, primitives, workflow topology.
public struct AbilityOperatingPolicy: Codable, Hashable, Sendable {
    public var phases: [String]
    public var guardrails: [String]
    public var successSignals: [String]
    public var stopConditions: [String]
    public var defaultSupportingAbilities: [AbilityID]
    /// Closed companion to UI-only `guardrails`. Prompt projection reads this field only.
    public var guardrailCategories: [GuardrailCategory]

    public init(
        phases: [String] = [],
        guardrails: [String] = [],
        successSignals: [String] = [],
        stopConditions: [String] = [],
        defaultSupportingAbilities: [AbilityID] = [],
        guardrailCategories: [GuardrailCategory] = []
    ) {
        self.phases = phases
        self.guardrails = guardrails
        self.successSignals = successSignals
        self.stopConditions = stopConditions
        self.defaultSupportingAbilities = defaultSupportingAbilities
        self.guardrailCategories = guardrailCategories
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case phases
        case guardrails
        case successSignals
        case stopConditions
        case defaultSupportingAbilities
        case guardrailCategories
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        phases = try values.decodeIfPresent([String].self, forKey: .phases) ?? []
        guardrails = try values.decodeIfPresent([String].self, forKey: .guardrails) ?? []
        successSignals = try values.decodeIfPresent([String].self, forKey: .successSignals) ?? []
        stopConditions = try values.decodeIfPresent([String].self, forKey: .stopConditions) ?? []
        defaultSupportingAbilities = try values.decodeIfPresent(
            [AbilityID].self, forKey: .defaultSupportingAbilities) ?? []
        guardrailCategories = try values.decodeIfPresent(
            [GuardrailCategory].self, forKey: .guardrailCategories) ?? []
    }
}

public struct AbilitySchema: Codable, Hashable, Sendable, Identifiable {
    public var id: AbilityID
    public var version: SemanticVersion
    public var title: String
    /// Inspector metadata. Prompt compiler never interpolates this text.
    public var summary: String
    public var tint: String
    public var aliases: [String]
    public var triggers: AbilityTriggerSchema
    public var skills: [SkillID]
    public var operatingPolicy: AbilityOperatingPolicy
    public var routing: RoutingPolicySchema
    public var totemProjections: [ProjectionID]
    /// Role. Nil for pre-field packages; read `MaryAbilityPackage.paradigm`.
    public var paradigm: AbilityParadigm?
    /// Non-plugin expertise list. Nil = silent; plugin packages use PluginSchema.application.
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

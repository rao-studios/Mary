//
//  AbilitySchema.swift
//  MaryFoundation
//
//  THE ABILITY ITSELF: how it presents, how it routes, what it may do while
//  it holds a turn, and which Skills and projections it exports.
//

import Foundation

/// Closed, Mary-owned caution categories shared by ability-level operating
/// policy (`AbilityOperatingPolicy.guardrailCategories`) and the
/// per-operation description extension (`PluginOperationSchema.caution`).
/// Modeled directly on `PluginOperationSemantics.role`: a package selects
/// only which closed category applies, never any wording. Every case maps to
/// exactly one fixed sentence the runtime owns outright, rendered in
/// `AbilityPromptProjection.render` (ability level) and
/// `AbilityRuntime.projectedBindingDescription` (operation level) — package
/// prose never reaches either seam through this type.
public enum GuardrailCategory: String, Codable, Hashable, Sendable, CaseIterable {
    /// Does not apply outside the surface kind it was built for — the
    /// recurring "never type prose into a code surface" shape.
    case domainMismatch
    /// Act only on the target the user explicitly named or focused, never an
    /// inferred neighbor.
    case unscopedTarget
    /// Read live state before acting or reporting; never answer from a
    /// remembered value.
    case staleState
    /// Never bring the target forward or steal focus merely to observe or
    /// command it.
    case noFocusSteal
    /// Issue this through the target application's own command, never
    /// synthesized input standing in for it.
    case nativeCommandOnly
    /// Can destroy or replace existing content; confirm the exact, fresh
    /// target before acting.
    case irreversibleAction
}

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
    /// Closed, bounded companion to `guardrails` — see `GuardrailCategory`.
    /// `guardrails` itself stays permanently free-text and UI-only, guarded
    /// by `AbilityPromptProjectionSecurityTests`; this field is the only
    /// ability-level caution signal the prompt projection ever reads.
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

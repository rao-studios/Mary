//
//  SkillSchemas.swift
//  MaryFoundation
//
//  WHAT: Skill declaration — ports, execution, model projection, artifact semantics.
//  IN:   `.mary` skills[] → AbilityPackageValidator+Skills.
//  OUT:  AbilityRuntime, ModelExposureSchema, Plugin realizations.
//

import Foundation

public enum SkillKind: String, Codable, Hashable, Sendable, CaseIterable {
    case cognitive
    case effectful
    case workflow
}

public enum SkillAccess: String, Codable, Hashable, Sendable, CaseIterable {
    case seamless
    case confirm
    case reversible
}

public struct SkillPortSchema: Codable, Hashable, Sendable {
    public var name: String
    public var valueType: ValueTypeID
    public var required: Bool
    public var summary: String

    public init(name: String, valueType: ValueTypeID, required: Bool = true, summary: String) {
        self.name = name
        self.valueType = valueType
        self.required = required
        self.summary = summary
    }
}

public struct SkillRequirements: Codable, Hashable, Sendable {
    public var capabilities: [CapabilityID]
    public var interactions: [InteractionID]
    public var perceptions: [PerceptionID]
    /// Enrich when present; not prerequisites. Ports may carry the same typed value.
    public var optionalInteractions: [InteractionID]
    public var optionalPerceptions: [PerceptionID]
    public var supportingAbilities: [AbilityID]

    public init(
        capabilities: [CapabilityID] = [],
        interactions: [InteractionID] = [],
        perceptions: [PerceptionID] = [],
        optionalInteractions: [InteractionID] = [],
        optionalPerceptions: [PerceptionID] = [],
        supportingAbilities: [AbilityID] = []
    ) {
        self.capabilities = capabilities
        self.interactions = interactions
        self.perceptions = perceptions
        self.optionalInteractions = optionalInteractions
        self.optionalPerceptions = optionalPerceptions
        self.supportingAbilities = supportingAbilities
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case interactions
        case perceptions
        case optionalInteractions
        case optionalPerceptions
        case supportingAbilities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try values.decodeIfPresent(
            [CapabilityID].self, forKey: .capabilities) ?? []
        interactions = try values.decodeIfPresent(
            [InteractionID].self, forKey: .interactions) ?? []
        perceptions = try values.decodeIfPresent(
            [PerceptionID].self, forKey: .perceptions) ?? []
        optionalInteractions = try values.decodeIfPresent(
            [InteractionID].self, forKey: .optionalInteractions) ?? []
        optionalPerceptions = try values.decodeIfPresent(
            [PerceptionID].self, forKey: .optionalPerceptions) ?? []
        supportingAbilities = try values.decodeIfPresent(
            [AbilityID].self, forKey: .supportingAbilities) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(capabilities, forKey: .capabilities)
        try values.encode(interactions, forKey: .interactions)
        try values.encode(perceptions, forKey: .perceptions)
        try values.encode(optionalInteractions, forKey: .optionalInteractions)
        try values.encode(optionalPerceptions, forKey: .optionalPerceptions)
        try values.encode(supportingAbilities, forKey: .supportingAbilities)
    }
}

public struct ModelParameterSchema: Codable, Hashable, Sendable {
    public var name: String
    public var type: String
    /// Inspector only. Provider wording is Mary's or the adapter's, never the package.
    public var summary: String
    public var required: Bool
    public var enumValues: [String]
    /// Package-authored escape hatch: this required string cannot be a spoken
    /// span even when it is the skill's ONLY required parameter — a commit
    /// message, replacement prose, a computed line number. Confidence-dispatch
    /// skips extraction eligibility for it and falls through to the model.
    public var requiresComposition: Bool
    /// THE WORDS A PERSON SAYS FOR EACH ENUM VALUE, keyed by the value.
    ///
    /// PIN: DATA, NOT A SWITCH — this is the whole reason it lives on the schema.
    /// An enum value is a machine word ("previous"); a person says "go back" or
    /// "last song". Bonnie carried that mapping as a Swift synonym table inside
    /// the music adapter, which meant every other platform's enum had none. Here
    /// the package that declares the enum declares how it is spoken, so a skill in
    /// any world gets the same treatment and no Swift file learns a verb.
    /// Empty is honest: an enum whose values ARE the words needs nothing here,
    /// because the value's own name is always matched first.
    public var spokenValues: [String: [String]]

    public init(
        name: String,
        type: String,
        summary: String,
        required: Bool,
        enumValues: [String] = [],
        requiresComposition: Bool = false,
        spokenValues: [String: [String]] = [:]
    ) {
        self.name = name
        self.type = type
        self.summary = summary
        self.required = required
        self.enumValues = enumValues
        self.requiresComposition = requiresComposition
        self.spokenValues = spokenValues
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, summary, required, enumValues, requiresComposition
        case spokenValues
    }

    /// Tolerant decode — a package sealed before this field existed must
    /// still load. Every field decodes with a default, not only the new one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues) ?? []
        requiresComposition = try container.decodeIfPresent(
            Bool.self, forKey: .requiresComposition) ?? false
        spokenValues = try container.decodeIfPresent(
            [String: [String]].self, forKey: .spokenValues) ?? [:]
    }
}

/// Model-call projection of a Skill. Wire adapters may say "tool"; Mary does not.
public struct ModelExposureSchema: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var invocationName: String?
    /// Inspector copy only — never the provider-facing callable description.
    public var summaryOverride: String?
    public var parameters: [ModelParameterSchema]
    public var inheritsBindingContract: Bool

    public init(
        enabled: Bool = true,
        invocationName: String? = nil,
        summaryOverride: String? = nil,
        parameters: [ModelParameterSchema] = [],
        inheritsBindingContract: Bool = true
    ) {
        self.enabled = enabled
        self.invocationName = invocationName
        self.summaryOverride = summaryOverride
        self.parameters = parameters
        self.inheritsBindingContract = inheritsBindingContract
    }
}

public struct WorkflowStepSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Installed Skill or Mary cognitive primitive. Data, never prompt prose.
    public var operation: String
    public var consumes: [String]
    public var produces: [String]
    public var onSuccess: String?
    public var onFailure: String?

    public init(
        id: String,
        operation: String,
        consumes: [String] = [],
        produces: [String] = [],
        onSuccess: String? = nil,
        onFailure: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.consumes = consumes
        self.produces = produces
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }
}

public struct SkillExecutionSchema: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case cognitive
        case binding
        case stateMachine
    }

    /// Own bindings vs portable contract waiting for a Plugin. Missing provider is readiness, not invalid.
    public enum RealizationPolicy: String, Codable, Hashable, Sendable, CaseIterable {
        case authoredBindings
        case pluginRealizations
    }

    public var kind: Kind
    public var bindings: [AdapterBindingReference]
    public var steps: [WorkflowStepSchema]
    public var realizationPolicy: RealizationPolicy

    public init(
        kind: Kind,
        bindings: [AdapterBindingReference] = [],
        steps: [WorkflowStepSchema] = [],
        realizationPolicy: RealizationPolicy = .authoredBindings
    ) {
        self.kind = kind
        self.bindings = bindings
        self.steps = steps
        self.realizationPolicy = realizationPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case bindings
        case steps
        case realizationPolicy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        bindings = try values.decodeIfPresent(
            [AdapterBindingReference].self, forKey: .bindings) ?? []
        steps = try values.decodeIfPresent(
            [WorkflowStepSchema].self, forKey: .steps) ?? []
        realizationPolicy = try values.decodeIfPresent(
            RealizationPolicy.self, forKey: .realizationPolicy) ?? .authoredBindings
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(bindings, forKey: .bindings)
        try values.encode(steps, forKey: .steps)
        if realizationPolicy != .authoredBindings {
            try values.encode(realizationPolicy, forKey: .realizationPolicy)
        }
    }
}

/// Declared artifact meaning. Wins over structural inference; no domain → nothing.
public struct SkillSemanticsSchema: Codable, Hashable, Sendable {
    public enum ArtifactRole: String, Codable, Hashable, Sendable, CaseIterable {
        /// New artifact. Requires `producesReference`.
        case create
        /// Existing artifact. Requires nonempty `targetParameters`.
        case mutate
        /// Whole semantic plan via the plugin's plan entry.
        case plan
        /// Read, no change.
        case observe
        /// Not create/mutate/observe (docs, pages, history). Explicit, not implied.
        case utility
    }

    public var artifactRole: ArtifactRole
    /// Created artifact's reference type. Required for `create`, else forbidden.
    public var producesReference: ValueTypeID?
    /// Parameter names aiming at existing artifacts. Required nonempty for `mutate`.
    public var targetParameters: [String]

    public init(
        artifactRole: ArtifactRole,
        producesReference: ValueTypeID? = nil,
        targetParameters: [String] = []
    ) {
        self.artifactRole = artifactRole
        self.producesReference = producesReference
        self.targetParameters = targetParameters
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case artifactRole
        case producesReference
        case targetParameters
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        artifactRole = try values.decode(ArtifactRole.self, forKey: .artifactRole)
        producesReference = try values.decodeIfPresent(ValueTypeID.self, forKey: .producesReference)
        targetParameters = try values.decodeIfPresent([String].self, forKey: .targetParameters) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(artifactRole, forKey: .artifactRole)
        try values.encodeIfPresent(producesReference, forKey: .producesReference)
        if !targetParameters.isEmpty {
            try values.encode(targetParameters, forKey: .targetParameters)
        }
    }
}

public struct SkillSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: SkillID
    public var version: SemanticVersion
    public var title: String
    /// Inspector metadata. Semantics live in the typed fields below.
    public var summary: String
    public var kind: SkillKind
    public var access: SkillAccess
    public var inputs: [SkillPortSchema]
    public var outputs: [SkillPortSchema]
    public var requirements: SkillRequirements
    public var routing: RoutingPolicySchema
    public var execution: SkillExecutionSchema
    public var modelExposure: ModelExposureSchema
    public var usesStage: Bool
    public var timeoutSeconds: Double?
    /// Artifact meaning. Nil → infer in a declared domain, else nothing (`SkillSemanticsSchema`).
    public var semantics: SkillSemanticsSchema?

    public init(
        id: SkillID,
        version: SemanticVersion = "1.0.0",
        title: String,
        summary: String,
        kind: SkillKind,
        access: SkillAccess = .seamless,
        inputs: [SkillPortSchema] = [],
        outputs: [SkillPortSchema] = [],
        requirements: SkillRequirements = .init(),
        routing: RoutingPolicySchema = .init(),
        execution: SkillExecutionSchema,
        modelExposure: ModelExposureSchema = .init(),
        usesStage: Bool = false,
        timeoutSeconds: Double? = nil,
        semantics: SkillSemanticsSchema? = nil
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.summary = summary
        self.kind = kind
        self.access = access
        self.inputs = inputs
        self.outputs = outputs
        self.requirements = requirements
        self.routing = routing
        self.execution = execution
        self.modelExposure = modelExposure
        self.usesStage = usesStage
        self.timeoutSeconds = timeoutSeconds
        self.semantics = semantics
    }

    /// Operation a model provider sees.
    public var invocationName: String? {
        guard modelExposure.enabled else { return nil }
        if let explicit = modelExposure.invocationName { return explicit }
        return execution.bindings.sorted { $0.preference > $1.preference }.first?.operation
    }
}

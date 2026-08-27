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
    /// Signals that enrich execution when present but are not prerequisites.
    /// A workflow may instead receive the same typed value explicitly through
    /// its input ports (for example, a named project with no focused IDE).
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
    /// Inspector metadata. Provider-facing wording is owned by Mary or the
    /// installed adapter implementation, never by an imported package.
    public var summary: String
    public var required: Bool
    public var enumValues: [String]

    public init(
        name: String,
        type: String,
        summary: String,
        required: Bool,
        enumValues: [String] = []
    ) {
        self.name = name
        self.type = type
        self.summary = summary
        self.required = required
        self.enumValues = enumValues
    }
}

/// The model-call projection of a Skill. It is deliberately a projection:
/// wire adapters may still call this a tool, but Mary's domain and UI do not.
public struct ModelExposureSchema: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var invocationName: String?
    /// Optional inspector copy only. It is intentionally excluded from the
    /// provider-facing callable description.
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
    /// A validated callable identifier resolved to a locally installed Skill
    /// or Mary-owned cognitive primitive. It is data, never prompt prose.
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

    /// Whether a binding Skill carries its own provider references or is an
    /// intentionally portable semantic contract waiting for a Plugin
    /// to realize it. The latter may remain installed while no provider is
    /// available; runtime readiness, not package validity, reports that state.
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

/// A skill's declared artifact meaning — what the engine previously
/// reverse-engineered from naming conventions (an output value-type suffix,
/// a parameter literally spelled "target"). Declaration always wins over
/// structural inference; a skill without semantics falls back to inference
/// parametrized by its application's artifact domain, and to nothing at all
/// when no domain is declared.
public struct SkillSemanticsSchema: Codable, Hashable, Sendable {
    public enum ArtifactRole: String, Codable, Hashable, Sendable, CaseIterable {
        /// Makes an artifact that did not exist. Requires `producesReference`.
        case create
        /// Changes an existing artifact. Requires nonempty `targetParameters`.
        case mutate
        /// Applies a whole semantic plan through the plugin's plan entry.
        case plan
        /// Reads without changing anything.
        case observe
        /// Neither creates, mutates, nor observes an artifact (documents,
        /// pages, history). Explicit beats implied-by-absence.
        case utility
    }

    public var artifactRole: ArtifactRole
    /// The value type of the created artifact's reference output. REQUIRED
    /// for `create`, forbidden otherwise.
    public var producesReference: ValueTypeID?
    /// The parameter names that aim this skill at existing artifacts.
    /// REQUIRED nonempty for `mutate`, forbidden otherwise.
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
    /// Inspector metadata. Runtime semantics come from the typed fields below.
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
    /// Declared artifact meaning. Absent means "infer structurally within a
    /// declared artifact domain, else nothing" — see `SkillSemanticsSchema`.
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

    /// The locally bound operation that an external model provider sees.
    public var invocationName: String? {
        guard modelExposure.enabled else { return nil }
        if let explicit = modelExposure.invocationName { return explicit }
        return execution.bindings.sorted { $0.preference > $1.preference }.first?.operation
    }
}

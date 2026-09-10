//
//  PluginOperationSchema.swift
//  MaryFoundation
//
//  WHAT: One declarative operation — inputs, recipe, cleanup, semantics.
//  IN:   PluginSchema.operations.
//  OUT:  PluginValidator+Operations, AbilityRuntime.
//

import Foundation

/// Closed meaning after routing admits the operation. Never grants target authority.
public struct PluginOperationSemantics: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable, CaseIterable {
        case utility
        case observe
        case createArtifact
        case mutateArtifact
    }

    public var role: Role
    /// Exact one-token artifact nouns admitted only for creation operations.
    public var aliases: [String]

    public init(role: Role, aliases: [String] = []) {
        self.role = role
        self.aliases = aliases
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case role
        case aliases
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decode(Role.self, forKey: .role)
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

public struct PluginOperationSchema: Codable, Hashable, Sendable, Identifiable {
    public var operation: String
    public var title: String
    /// Inspector-only annotation. It never becomes model instruction text.
    public var summary: String
    /// Adapter that interprets this operation. Required when several are declared.
    public var adapterID: AdapterID?
    public var semantics: PluginOperationSemantics?
    /// GuardrailCategory. AbilityRuntime appends one Mary-owned sentence.
    public var caution: GuardrailCategory?
    public var inputs: [PluginOperationInputSchema]
    public var steps: [PluginRecipeStepSchema]
    /// Cleanup before restore. Skipped after physical user intervention.
    public var cleanupSteps: [PluginRecipeStepSchema]
    public var postconditions: [PluginRecipePostcondition]
    public var timeoutSeconds: Double

    public init(
        operation: String,
        title: String,
        summary: String,
        adapterID: AdapterID? = nil,
        semantics: PluginOperationSemantics? = nil,
        caution: GuardrailCategory? = nil,
        inputs: [PluginOperationInputSchema] = [],
        steps: [PluginRecipeStepSchema] = [],
        cleanupSteps: [PluginRecipeStepSchema] = [],
        postconditions: [PluginRecipePostcondition] = [.applicationFrontmost],
        timeoutSeconds: Double = 10
    ) {
        self.operation = operation
        self.title = title
        self.summary = summary
        self.adapterID = adapterID
        self.semantics = semantics
        self.caution = caution
        self.inputs = inputs
        self.steps = steps
        self.cleanupSteps = cleanupSteps
        self.postconditions = postconditions
        self.timeoutSeconds = timeoutSeconds
    }

    public var id: String { operation }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operation
        case title
        case summary
        case adapterID
        case semantics
        case caution
        case inputs
        case steps
        case cleanupSteps
        // Tombstoned executable recipes: reject, do not ignore.
        case commands
        case output
        case postconditions
        case timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(String.self, forKey: .operation)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        adapterID = try container.decodeIfPresent(AdapterID.self, forKey: .adapterID)
        semantics = try container.decodeIfPresent(
            PluginOperationSemantics.self, forKey: .semantics)
        caution = try container.decodeIfPresent(GuardrailCategory.self, forKey: .caution)
        inputs = try container.decode([PluginOperationInputSchema].self, forKey: .inputs)
        if container.contains(.commands) || container.contains(.output) {
            let key: CodingKeys = container.contains(.commands) ? .commands : .output
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Plugin operations are native data-only recipes; scripted commands and script-produced outputs are not supported.")
        }
        steps = try container.decodeIfPresent([PluginRecipeStepSchema].self, forKey: .steps) ?? []
        cleanupSteps = try container.decodeIfPresent(
            [PluginRecipeStepSchema].self, forKey: .cleanupSteps) ?? []
        postconditions = try container.decode(
            [PluginRecipePostcondition].self, forKey: .postconditions)
        timeoutSeconds = try container.decode(Double.self, forKey: .timeoutSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .operation)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        if let adapterID {
            try container.encode(adapterID, forKey: .adapterID)
        }
        if let semantics {
            try container.encode(semantics, forKey: .semantics)
        }
        if let caution {
            try container.encode(caution, forKey: .caution)
        }
        try container.encode(inputs, forKey: .inputs)
        try container.encode(steps, forKey: .steps)
        if !cleanupSteps.isEmpty {
            try container.encode(cleanupSteps, forKey: .cleanupSteps)
        }
        try container.encode(postconditions, forKey: .postconditions)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }
}

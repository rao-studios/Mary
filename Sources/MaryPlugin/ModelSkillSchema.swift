//
//  ModelSkillSchema.swift
//  MaryPlugin
//
//  WHAT: Neutral description of a callable Skill.
//  IN:   SkillBinding (plugin authors fill parameters)
//  OUT:  provider adapters → wire tool declarations
//  PIN:  Lives with the contract, like SkillOutcome — the engine only reads it.
//

import Foundation

/// Neutral Skill description. Providers render this into ToolSpec / input_schema.
public struct ModelSkillSchema: Sendable {
    public struct Parameter: Sendable {
        public var name: String
    /// JSON Schema type: "string", "boolean", "integer", "number".
        public var type: String
        public var description: String
        public var required: Bool
        public var enumValues: [String]?
        /// Inclusive JSON Schema bounds. Nil = that side undeclared.
        public var minimum: Double?
        public var maximum: Double?
        /// Other names a model may write. Matched exactly (case-insensitive).
        /// PIN: never sent on the wire — rescue for a call already made.
        ///      Containment matching copied values into sibling parameters.
        public var aliases: [String]

        public init(
            name: String,
            type: String,
            description: String,
            required: Bool,
            enumValues: [String]? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil,
            aliases: [String] = []
        ) {
            self.name = name
            self.type = type
            self.description = description
            self.required = required
            self.enumValues = enumValues
            self.minimum = minimum
            self.maximum = maximum
            self.aliases = aliases
        }
    }

    public var name: String
    public var description: String
    public var parameters: [Parameter]

    public init(name: String, description: String, parameters: [Parameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

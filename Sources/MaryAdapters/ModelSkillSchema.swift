//
//  ModelSkillSchema.swift
//
//  The neutral description of a callable Skill. Provider adapters render it
//  into wire-specific tool declarations; a plugin author fills in the
//  parameters half when declaring a SkillBinding.
//
//  Here rather than in the engine for the same reason as SkillOutcome: it is
//  part of what a plugin DECLARES, and the engine is only its first reader.
//

import Foundation

/// The neutral description of a callable Skill. Provider adapters render it
/// into wire-specific tool declarations such as ToolSpec or input_schema.
public struct ModelSkillSchema: Sendable {
    public struct Parameter: Sendable {
        public var name: String
        /// JSON Schema type: "string", "boolean", "integer", "number".
        public var type: String
        public var description: String
        public var required: Bool
        public var enumValues: [String]?
        /// Inclusive JSON Schema bounds for numeric inputs. Nil means the
        /// provider does not declare that side of the range.
        public var minimum: Double?
        public var maximum: Double?

        public init(
            name: String,
            type: String,
            description: String,
            required: Bool,
            enumValues: [String]? = nil,
            minimum: Double? = nil,
            maximum: Double? = nil
        ) {
            self.name = name
            self.type = type
            self.description = description
            self.required = required
            self.enumValues = enumValues
            self.minimum = minimum
            self.maximum = maximum
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

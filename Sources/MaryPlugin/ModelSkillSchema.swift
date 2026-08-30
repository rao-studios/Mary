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
        /// OTHER NAMES A MODEL PLAUSIBLY WRITES FOR THIS PARAMETER.
        ///
        /// THE FAILURE THIS FIXES (live): `bring_window_forward` declares
        /// `window`; a model asked to raise "Untitled 47" sent
        /// `{"app":"TextEdit","title":"Untitled 47"}` — `title` is the more
        /// natural word for a window's name, and it is not wrong, it is just
        /// not the declared spelling. `reconcile`'s substring heuristic needs
        /// one name to contain the other, so it could not bridge them; the
        /// binding coalesced the miss to `""`, and the user was told
        /// `I couldn't find one open window matching ""` — a refusal over
        /// vocabulary, reported as a fact about their windows.
        ///
        /// These are declared rather than guessed, and matched EXACTLY (case
        /// -insensitively) rather than by containment, because the loose test
        /// is what let a correctly-placed value be copied into a sibling
        /// parameter — see `reconcile`'s own note about `fill` / `fill_type`.
        /// They are never sent to the model: the wire schema advertises the
        /// declared name alone, so an alias is a rescue for a call already
        /// made, not a second spelling the model is invited to choose.
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

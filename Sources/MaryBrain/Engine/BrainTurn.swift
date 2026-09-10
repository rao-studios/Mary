//
//  BrainTurn.swift
//  MaryBrain
//
//  WHAT: One turn of neutral conversation history, plus the Skill invocation it carries.
//  IN:   the turn loop and every lane that appends history
//  OUT:  each engine maps it onto its own wire format
//  PIN:  `id` anchors deferred writes — a detached routine's follow-up merges into
//        its ORIGINATING exchange, not whatever turn is positionally last. Engines
//        never see or send it.
//

import Foundation

/// One turn of neutral conversation history. Each engine maps this onto its
/// own wire format (Chat.Message for MLX, Anthropic content blocks for Tinker).
public struct BrainTurn: Sendable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
        /// The result of a Skill the assistant invoked.
        case skillResult
    }

    public var role: Role
    public var text: String
    /// Assistant turns: the model-facing Skill invocations made this turn.
    public var skillInvocations: [ModelSkillInvocation]
    /// Skill-result turns: which invocation this result answers.
    public var skillInvocationID: String?
    public var skillName: String?
    /// Stable identity, used to anchor deferred writes (a detached routine's
    /// follow-up merges into its ORIGINATING exchange, not whatever turn is
    /// positionally last by then). Engines never see or send it.
    public let id: UUID

    public init(
        role: Role,
        text: String,
        skillInvocations: [ModelSkillInvocation] = [],
        skillInvocationID: String? = nil,
        skillName: String? = nil,
        id: UUID = UUID()
    ) {
        self.role = role
        self.text = text
        self.skillInvocations = skillInvocations
        self.skillInvocationID = skillInvocationID
        self.skillName = skillName
        self.id = id
    }
}

/// A Skill invocation the model made, in a transport-neutral shape.
public struct ModelSkillInvocation: Sendable {
    /// Provider adapters map this id onto their wire-level call/result pair.
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

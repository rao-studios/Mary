//
//  InferenceEngine.swift
//  MaryBrain
//
//  WHAT: Seam — one round of (system, history, skills) → EngineEvent stream.
//  IN:   MaryBrain turn loop
//  OUT:  MaryLocalEngine / MarySeerSkillEngine / coding engines
//  PIN:  Enum is where (on-device vs hosted), not who (vendor).
//
import Foundation
import MaryFoundation

/// Which inference engine answers Mary's turns.
public enum LLMEngineChoice: String, Codable, CaseIterable, Sendable {
    /// On-device, through MLX. Nothing leaves the machine.
    case local
    /// The local Seer server, which reaches the cloud on Mary's behalf.
    case hosted

    public var displayName: String {
        switch self {
        case .local:  return "On-device"
        case .hosted: return "Hosted (via Seer)"
        }
    }
}

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

/// One round's worth of streamed model output.
public enum EngineEvent: Sendable {
    case text(String)
    case skillInvocation(ModelSkillInvocation)
    case done
}

public protocol InferenceEngine: Sendable {
    /// Human-readable name for status surfaces.
    var displayName: String { get }
    /// WHICH LANE THIS IS, for the behavioral record.
    var choice: LLMEngineChoice { get }
    /// Load/verify whatever the engine needs before the first turn.
    func warmup() async throws
    /// Stream one completion round. The stream finishes after `.done` (or throws).
    func stream(
        system: String,
        history: [BrainTurn],
        skills: [ModelSkillSchema]
    ) -> AsyncThrowingStream<EngineEvent, Error>
    /// True when concurrent `stream` calls are unsafe (a local MLX model) — the brain then serializes generation rounds across concurrent lanes.
    var requiresExclusiveGeneration: Bool { get }
    /// Gated JSON complete for a loaded LoRA. Default: unsupported.
    func completeCodec(
        input: BehavioralTrainingInput,
        schemaJSON: Data,
        adapterPath: URL
    ) async throws -> BehavioralTrainingOutput
}

public extension InferenceEngine {
    var requiresExclusiveGeneration: Bool { false }
    /// Local is the safe default for a conformer that has not said: an engine
    /// mislabelled as on-device understates where the data went, and that is
    /// the direction to be wrong in.
    var choice: LLMEngineChoice { .local }

    func completeCodec(
        input: BehavioralTrainingInput,
        schemaJSON: Data,
        adapterPath: URL
    ) async throws -> BehavioralTrainingOutput {
        throw CodecCompleteError.unsupported
    }
}

public enum CodecCompleteError: Error, Sendable {
    case unsupported
    case noAdapter
    case invalidSchema
}

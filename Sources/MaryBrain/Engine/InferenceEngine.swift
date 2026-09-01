//
//  InferenceEngine.swift
//  MaryBrain
//
//  WHAT: Seam — one round of (system, history, skills) → EngineEvent stream.
//  IN:   MaryBrain turn loop
//  OUT:  MaryLocalEngine / MarySeerSkillEngine / coding engines
//  PIN:  The protocol and its event stream only. What flows THROUGH it lives
//        beside it: BrainTurn.swift (history + ModelSkillInvocation) and
//        LLMEngineChoice.swift (where inference runs — never who vends it).
//
import Foundation
import MaryFoundation

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

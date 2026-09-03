//
//  LifeAdapterSession.swift
//  MaryBrain
//
//  WHAT: One LoRA, loaded, answering gated JSON completions.
//  IN:   MaryLifeEngine (which owns the cache and the reload rule)
//  OUT:  LifeCompletion
//  PIN:  The ONLY place in Mary that names Fleet's decoder. The conversation
//        engine no longer carries a codec method it never used for talking.
//
import Foundation
import FleetCore
import FleetInference
import MaryFoundation

/// Fleet's `StructuredSession` behind the engine's seam.
public struct FleetAdapterSessionMaker: LifeAdapterSessionMaking {

    /// Base model the codec must run on. An adapter trained against a
    /// different base is refused rather than quietly loaded onto this one.
    private let modelID: String
    /// Held while a completion runs, so codec decode and conversation
    /// generation never touch the GPU at the same time.
    private let gate: @Sendable () async -> Void
    private let ungate: @Sendable () -> Void

    public init(modelID: String) {
        self.init(
            modelID: modelID,
            gate: { await MLXGPUGate.shared.acquire() },
            ungate: { Task { await MLXGPUGate.shared.release() } })
    }

    init(
        modelID: String,
        gate: @escaping @Sendable () async -> Void,
        ungate: @escaping @Sendable () -> Void
    ) {
        self.modelID = modelID
        self.gate = gate
        self.ungate = ungate
    }

    public func makeSession(adapter: LifeAdapterRef) throws -> any LifeAdapterSessioning {
        // AN ADAPTER KNOWS WHICH BASE IT LEARNED ON. Loading rank-8 deltas
        // trained on one model into another produces confident nonsense that
        // the schema gate will still make well-formed — the worst shape of
        // wrong for a path that acts unattended.
        guard adapter.modelID.isEmpty || adapter.modelID == modelID else {
            throw LifeEngineError.modelMismatch(
                expected: modelID, got: adapter.modelID)
        }
        return FleetAdapterSession(
            session: StructuredSession(
                modelId: modelID,
                adapterDirectory: URL(fileURLWithPath: adapter.artifactPath)),
            gate: gate,
            ungate: ungate)
    }
}

struct FleetAdapterSession: LifeAdapterSessioning {

    let session: StructuredSession
    let gate: @Sendable () async -> Void
    let ungate: @Sendable () -> Void

    func complete(
        input: BehavioralTrainingInput, schemaJSON: Data
    ) async throws -> LifeCompletion {
        guard let schema = try? JSONDecoder().decode(SchemaTemplate.self, from: schemaJSON)
        else { throw LifeEngineError.invalidSchema }
        let bytes = try BehavioralCodec.encoder().encode(input)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw LifeEngineError.invalidSchema
        }
        let json = try JSONParser.parse(text)
        await gate()
        defer { ungate() }
        let result = try await session.complete(input: json, schema: schema)
        let output = try BehavioralCodec.decoder().decode(
            BehavioralTrainingOutput.self, from: Data(result.rawText.utf8))
        return LifeCompletion(
            output: output,
            forcedFraction: result.forcedFraction,
            promptTokens: result.promptTokenCount)
    }
}

//
//  FleetRemoteAdapterSession.swift
//  MaryRuntime
//
//  WHAT: The Life engine's adapter session, answered by Fleet over gRPC.
//  IN:   MaryLifeEngine (which owns the cache and the reload rule)
//  OUT:  LifeCompletion
//  PIN:  Mary loads no model. The LoRA and its base run in Fleet, which owns
//        the schema by cid — so nothing here decodes a SchemaTemplate, and
//        MaryBrain no longer names FleetInference at all.
//
import Foundation
import MaryBrain
import MaryFoundation
import MaryTotem

/// The one call the session needs, behind a seam so a test needs no server.
package protocol FleetCompleting: Sendable {
    func complete(
        totemID: String, abilityID: String, cid: String, inputJSON: String
    ) async throws -> FleetCompletion
}

extension FleetDirectClient: FleetCompleting {}

/// Builds sessions that dial Fleet. One per adapter, cached by the engine.
package struct FleetRemoteAdapterSessionMaker: LifeAdapterSessionMaking {

    /// Base model the adapter must have learned on.
    private let modelID: String
    private let totemID: @Sendable () -> String
    private let fleet: @Sendable () -> any FleetCompleting

    package init(
        modelID: String,
        totemID: @escaping @Sendable () -> String,
        fleet: @escaping @Sendable () -> any FleetCompleting
    ) {
        self.modelID = modelID
        self.totemID = totemID
        self.fleet = fleet
    }

    package func makeSession(adapter: LifeAdapterRef) throws -> any LifeAdapterSessioning {
        // AN ADAPTER KNOWS WHICH BASE IT LEARNED ON. Fleet checks this too,
        // but refusing here costs no round trip and reads as one failure.
        guard adapter.modelID.isEmpty || adapter.modelID == modelID else {
            throw LifeEngineError.modelMismatch(
                expected: modelID, got: adapter.modelID)
        }
        return FleetRemoteAdapterSession(
            abilityID: adapter.abilityID.rawValue,
            cid: adapter.cid,
            totemID: totemID,
            fleet: fleet)
    }
}

struct FleetRemoteAdapterSession: LifeAdapterSessioning {

    let abilityID: String
    /// Pinned: retrained weights under the same path are a different cid, and
    /// Fleet answers with the live one rather than the stale generation.
    let cid: String
    let totemID: @Sendable () -> String
    let fleet: @Sendable () -> any FleetCompleting

    func complete(
        input: BehavioralTrainingInput, schemaJSON: Data
    ) async throws -> LifeCompletion {
        let bytes = try BehavioralCodec.encoder().encode(input)
        guard let inputJSON = String(data: bytes, encoding: .utf8) else {
            throw LifeEngineError.invalidSchema
        }
        let totem = totemID()
        guard !totem.isEmpty else {
            throw LifeEngineError.fleetUnreachable("no totem node id")
        }
        let answer: FleetCompletion
        do {
            answer = try await fleet().complete(
                totemID: totem, abilityID: abilityID, cid: cid, inputJSON: inputJSON)
        } catch {
            // `String(describing:)`, not `localizedDescription`: an RPCError's
            // code and message are what say whether the slot was missing, was
            // training, or the server is simply not there — and the localized
            // form prints none of it.
            throw LifeEngineError.fleetUnreachable(String(describing: error))
        }
        let output = try BehavioralCodec.decoder().decode(
            BehavioralTrainingOutput.self, from: Data(answer.rawText.utf8))
        return LifeCompletion(
            output: output,
            forcedFraction: answer.forcedFraction,
            promptTokens: answer.promptTokens)
    }
}

//
//  FleetRemoteAdapterSessionTests.swift
//  MaryRuntimeTests
//
//  WHAT: The Life engine's adapter round, now answered by Fleet over gRPC.
//  PIN:  The base-model guard fires BEFORE the dial — loading rank-8 deltas
//        onto a different base produces confident nonsense the schema gate
//        would still make well-formed.
//

import Foundation
import Testing
import MaryBrain
import MaryFoundation
import MaryTotem
@testable import MaryRuntime

private actor ScriptedFleet: FleetCompleting {
    let answer: FleetCompletion?
    let failure: Error?
    private(set) var calls: [(totemID: String, abilityID: String, cid: String)] = []

    init(answer: FleetCompletion? = nil, failure: Error? = nil) {
        self.answer = answer
        self.failure = failure
    }

    func complete(
        totemID: String, abilityID: String, cid: String, inputJSON: String
    ) async throws -> FleetCompletion {
        calls.append((totemID, abilityID, cid))
        if let failure { throw failure }
        return answer!
    }

    func callCount() -> Int { calls.count }
    func lastCID() -> String? { calls.last?.cid }
}

private struct Unreachable: Error, LocalizedError {
    var errorDescription: String? { "connection refused" }
}

@Suite struct FleetRemoteAdapterSessionTests {

    private func adapter(
        modelID: String = LifeBaseModel.defaultModelID, cid: String = "cid-1"
    ) -> LifeAdapterRef {
        LifeAdapterRef(
            abilityID: AbilityID("email.triage"),
            cid: cid,
            generation: 2,
            pairCount: 40,
            modelID: modelID,
            artifactPath: "/tmp/adapter",
            ready: true,
            training: false,
            trainedAt: nil)
    }

    private func maker(_ fleet: any FleetCompleting) -> FleetRemoteAdapterSessionMaker {
        FleetRemoteAdapterSessionMaker(
            modelID: LifeBaseModel.defaultModelID,
            totemID: { "totem-1" },
            fleet: { fleet })
    }

    /// The refusal that must not cost a round trip.
    @Test func anAdapterTrainedOnAnotherBaseIsRefusedBeforeDialling() async throws {
        let fleet = ScriptedFleet(answer: nil, failure: Unreachable())
        #expect(throws: LifeEngineError.self) {
            _ = try maker(fleet).makeSession(
                adapter: adapter(modelID: "mlx-community/Qwen3-4B"))
        }
        #expect(await fleet.callCount() == 0)
    }

    @Test func anAdapterWithNoRecordedBaseIsAccepted() throws {
        _ = try maker(ScriptedFleet(answer: nil)).makeSession(adapter: adapter(modelID: ""))
    }

    @Test func theAnswersRawTextDecodesIntoTheBehavioralOutput() async throws {
        let output = BehavioralTrainingOutput(actions: [])
        let raw = String(
            data: try BehavioralCodec.encoder().encode(output), encoding: .utf8) ?? "{}"
        let fleet = ScriptedFleet(answer: FleetCompletion(
            outputJSON: raw, rawText: raw, forcedFraction: 0.5,
            promptTokens: 128, cid: "cid-1"))
        let session = try maker(fleet).makeSession(adapter: adapter())
        let completion = try await session.complete(
            input: BehavioralTrainingInput(input: BehavioralInput(query: "idle")),
            schemaJSON: Data("{}".utf8))
        #expect(completion.forcedFraction == 0.5)
        #expect(completion.promptTokens == 128)
        #expect(await fleet.lastCID() == "cid-1")
    }

    /// A server that will not answer is its own failure, distinct from an
    /// adapter that answered badly — the Life sheet says which.
    @Test func anUnreachableFleetSurfacesAsItsOwnFailure() async throws {
        let session = try maker(ScriptedFleet(failure: Unreachable()))
            .makeSession(adapter: adapter())
        await #expect(throws: LifeEngineError.self) {
            _ = try await session.complete(
                input: BehavioralTrainingInput(input: BehavioralInput(query: "idle")),
                schemaJSON: Data("{}".utf8))
        }
    }

    /// Without a node id there is no slot to ask for; saying so beats a
    /// confusing gRPC error from an empty key.
    @Test func aMissingTotemNodeIsReportedRatherThanDialled() async throws {
        let fleet = ScriptedFleet(answer: nil)
        let maker = FleetRemoteAdapterSessionMaker(
            modelID: LifeBaseModel.defaultModelID,
            totemID: { "" },
            fleet: { fleet })
        let session = try maker.makeSession(adapter: adapter())
        await #expect(throws: LifeEngineError.self) {
            _ = try await session.complete(
                input: BehavioralTrainingInput(input: BehavioralInput(query: "idle")),
                schemaJSON: Data("{}".utf8))
        }
        #expect(await fleet.callCount() == 0)
    }
}

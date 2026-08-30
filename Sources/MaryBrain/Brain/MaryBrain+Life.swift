//
//  MaryBrain+Life.swift
//  MaryBrain
//
//  Gated codec acting (when a discipline LoRA is ready) and the proactive
//  Life path Runtime drives from an idle pulse.
//

import Foundation
import MaryFoundation
import os

extension MaryBrain {

    /// Stream for one acting round: codec complete when a LoRA is ready for
    /// this turn's discipline, otherwise unadapted tool-calling.
    func actingEvents(
        system: String,
        history: [BrainTurn],
        skills: [ModelSkillSchema]
    ) async -> AsyncThrowingStream<EngineEvent, Error> {
        if let invocations = await codecInvocationsIfReady() {
            return AsyncThrowingStream { continuation in
                for invocation in invocations {
                    continuation.yield(.skillInvocation(invocation))
                }
                continuation.yield(.done)
                continuation.finish()
            }
        }
        return engine.stream(system: system, history: history, skills: skills)
    }

    func codecInvocationsIfReady() async -> [ModelSkillInvocation]? {
        guard engine.choice == .local else { return nil }
        guard let snapshot = wiring.behavior.openSnapshot() else { return nil }
        let disciplines = snapshot.targets.filter { $0.paradigm == .discipline }
        guard let target = disciplines.first(where: { lookup in
            lifeLoRALookup?(lookup.abilityID)?.ready == true
        }) ?? disciplines.first,
              let slot = lifeLoRALookup?(target.abilityID),
              slot.ready
        else { return nil }
        let input = BehavioralTrainingInput(input: snapshot.input)
        do {
            let output = try await engine.completeCodec(
                input: input,
                schemaJSON: slot.schemaJSON,
                adapterPath: URL(fileURLWithPath: slot.artifactPath))
            return output.actions.enumerated().map { index, action in
                ModelSkillInvocation(
                    id: "life-\(snapshot.id.uuidString.lowercased())-\(index)",
                    name: action.invocationName.isEmpty
                        ? action.intention : action.invocationName,
                    argumentsJSON: action.argumentsJSON.isEmpty
                        ? "{}" : action.argumentsJSON)
            }
        } catch {
            Logger(subsystem: "nyc.rao.mary", category: "life")
                .error("codec acting dropped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Open a proactive episode, run predicted actions through the existing
    /// dispatcher, and seal completed. Idle + LoRA-ready + JSON round-trip
    /// are the gates; confirmation is not one of them.
    public func runProactiveLife(episode: BehavioralEpisode) async {
        wiring.behavior.openEpisode(
            id: episode.id,
            query: episode.input.query,
            priorEpisodeID: episode.input.priorEpisodeID,
            provenance: episode.provenance)
        if let ambient = episode.input.ambient {
            wiring.behavior.stageCapture(ambient)
            wiring.behavior.claimStagedCapture(forEpisode: episode.id)
        }
        wiring.behavior.noteAbilityTargets(episode.abilityTargets, forEpisode: episode.id)
        let actions = episode.output.actions.map(\.action)
        if !actions.isEmpty {
            _ = await dispatcher?.perform(sequence: actions, episodeID: episode.id)
        }
        wiring.behavior.seal(episode.id, reason: .completed)
    }

    /// Gated JSON complete through the current engine. Hosted engines throw
    /// `CodecCompleteError.unsupported` and the idle loop drops the pulse.
    public func completeCodec(
        input: BehavioralTrainingInput,
        schemaJSON: Data,
        adapterPath: URL
    ) async throws -> BehavioralTrainingOutput {
        try await engine.completeCodec(
            input: input, schemaJSON: schemaJSON, adapterPath: adapterPath)
    }
}

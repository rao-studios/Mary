//
//  MaryBrain+Life.swift
//  MaryBrain
//
//  WHAT: The turn's one question for the Life engine — does a ready,
//        opted-in adapter answer this round instead of the model?
//  IN:   MaryLifeEngine (installed by Runtime)
//  OUT:  acting events
//  PIN:  The brain holds the engine; it does not hold adapters, sessions, or
//        Fleet. Everything the idle path does lives in MaryLifeEngine.
//
import Foundation
import MaryFoundation

extension MaryBrain {

    /// Stream for one acting round: an opted-in adapter's codec output when
    /// there is one, otherwise ordinary tool-calling.
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
        guard engine.choice == .local,
              let lifeEngine,
              let snapshot = wiring.behavior.openSnapshot()
        else { return nil }
        let invocations = await lifeEngine.turnInvocations(
            targets: snapshot.targets,
            input: BehavioralTrainingInput(input: snapshot.input),
            episodeID: snapshot.id)
        // An adapter that answered with nothing has not answered the turn.
        guard let invocations, !invocations.isEmpty else { return nil }
        return invocations
    }
}

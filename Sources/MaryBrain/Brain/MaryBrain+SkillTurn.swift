//
//  MaryBrain+SkillTurn.swift
//  MaryBrain
//
//  WHAT: The invocation ceremony every deterministic dispatch shares.
//  IN:   runTurnBody's decision / prose / confidence dispatch paths
//  OUT:  SkillOutcome, with the invocation + result pair already in history
//  PIN:  Speaking and closing stay with the caller — the decision path speaks
//        much later, from the seer epilogue, and must not close its own turn.
//
import MaryPlugin
import MaryVoice
import Foundation

extension MaryBrain {

    /// Yield the invocation, dispatch it, yield the result row, append the
    /// invocation/result history pair. FOUR PATHS WROTE THIS OUT LONGHAND;
    /// the only thing that ever differed is the title-commit arming.
    @discardableResult
    func performSkillTurn(
        dispatcher: any AbilityDispatching,
        name: String,
        argumentsJSON: String,
        runIDPrefix: String,
        /// Armed only for a shortcut dispatch — a title match with no exact
        /// candidate may commit to its best guess rather than refuse. Lane B
        /// and model-driven dispatches never set this.
        allowTitleCommit: Bool = false,
        /// What this dispatch may teach the router, or nil to teach nothing.
        /// Only the paths that ARE a routing decision pass one: the deciding
        /// gates (confirm/cancel), the accepted-prose road (whose utterance is
        /// "yes please", not a way of asking for anything) and the window
        /// verbs' old hand-written gate never did.
        exemplarGrant: ExemplarRecordingContext.Grant? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async -> SkillOutcome {
        let invocation = ModelSkillInvocation(
            id: "\(runIDPrefix)-\(UUID().uuidString)", name: name,
            argumentsJSON: argumentsJSON)
        let invocationReference = dispatcher.skillReference(for: name)
        continuation.yield(.skillInvocation(
            reference: invocationReference, argumentsJSON: argumentsJSON,
            runID: invocation.id))
        let startedAt = Date()
        let outcome: SkillOutcome = await ExemplarRecordingContext.withGrant(exemplarGrant) {
            if allowTitleCommit {
                return await SpokenTitleCommitContext.$allowed.withValue(true) {
                    await dispatcher.dispatch(
                        name: name, argumentsJSON: argumentsJSON, runID: invocation.id)
                }
            }
            return await dispatcher.dispatch(
                name: name, argumentsJSON: argumentsJSON, runID: invocation.id)
        }
        continuation.yield(.skillResult(record: BehavioralActionRecord(
            outcome: outcome,
            intention: name,
            argumentsJSON: argumentsJSON,
            reference: invocationReference,
            runID: invocation.id,
            startedAt: startedAt)))
        appendHistory(contentsOf: [
            BrainTurn(role: .assistant, text: "", skillInvocations: [invocation]),
            BrainTurn(
                role: .skillResult,
                text: outcome.summary,
                skillInvocationID: invocation.id,
                skillName: name
            ),
        ], epoch: epoch)
        return outcome
    }

    /// The tail the three EARLY-RETURNING dispatch paths share: speak when
    /// there is something to say, then close the turn. An empty `spoken` still
    /// completes — the act was the answer.
    func closeSkillTurn(
        spoken: String,
        exit: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) {
        if !spoken.isEmpty {
            continuation.yield(.token(spoken))
            appendHistory(BrainTurn(role: .assistant, text: spoken), epoch: epoch)
        }
        continuation.yield(.completed(fullText: spoken))
        logTurnExit(exit)
        continuation.finish()
    }

    /// JSON for a flat string map, in the stable key order every dispatch path
    /// already used.
    static func argumentsJSON(_ arguments: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

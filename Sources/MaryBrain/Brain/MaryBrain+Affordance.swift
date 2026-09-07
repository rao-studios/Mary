//
//  MaryBrain+Affordance.swift
//  MaryBrain
//
//  WHAT: Last rung before the honest failure — dispatch the offered on-screen Skill.
//  IN:   affordance nudge named a Skill; model declined
//  OUT:  act_on_screen via the same resolution ladder
//  PIN:  Not a private path; can do nothing the model could not.
//
import MaryAmbient
import MaryPlugin
import MaryVoice
import Foundation

extension MaryBrain {

    /// The affordance act, run as though the model had called it. Returns the outcome, or nil when there was no dispatcher to run it.
    func dispatchAffordanceAct(
        goal: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async -> SkillOutcome? {
        guard let dispatcher else { return nil }
        // The plugin names its own Skill and its own argument shape.
        let skillName = AffordancePlugin.actSkillName
        let argumentsJSON = AffordancePlugin.actArguments(goal: goal)
        let invocation = ModelSkillInvocation(
            id: "afford-\(UUID().uuidString)",
            name: skillName,
            argumentsJSON: argumentsJSON)
        let invocationReference = dispatcher.skillReference(for: skillName)
        Self.laneLog.info("the lane declined a named control twice — pressing it deterministically")
        continuation.yield(.skillInvocation(
            reference: invocationReference, argumentsJSON: argumentsJSON,
            runID: invocation.id))
        let startedAt = Date()
        let outcome = await dispatcher.dispatch(
            name: skillName, argumentsJSON: argumentsJSON,
            runID: invocation.id)
        continuation.yield(.skillResult(record: BehavioralActionRecord(
            outcome: outcome,
            intention: skillName,
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
                skillName: skillName),
        ], epoch: epoch)
        return outcome
    }
}

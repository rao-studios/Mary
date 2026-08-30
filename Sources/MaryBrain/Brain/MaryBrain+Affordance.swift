//
//  MaryBrain+Affordance.swift
//  MaryBrain
//
//  THE LAST RUNG BEFORE THE HONEST FAILURE.
//
//  `OfferedProse` names the rule this obeys: "an ignored instruction gets
//  replaced by a mechanism". Its incident was a user saying "please write
//  that" about prose Mary had just composed, and hearing "I couldn't work
//  out how to do that". This is the same shape one lane over — the user asked
//  for something the screen was plainly offering, the lane was told so BY
//  NAME in the affordance nudge, and it declined anyway.
//
//  IT DISPATCHES THE SAME SKILL THE MODEL WAS OFFERED, with the user's own
//  words as the goal. Not a private path: `act_on_screen` runs its full
//  choreography — the resolution ladder, the stage lease, verified
//  activation, the fresh re-read, an ambiguity refusal that names rivals — so
//  a deterministic dispatch can do nothing the model could not have done, and
//  cannot press anything the resolver would have refused.
//
//  THE FLOOR IS PART OF THE HONESTY. Two declines are evidence. Below
//  `AffordanceProbe.confidentFloor` the candidate is a guess, and this rung
//  stands down so the honest failure can stand — which is why the gate lives
//  at the call site, in plain view of the sentence it is replacing.
//

import MaryAmbient
import MaryPlugin
import MaryVoice
import Foundation

extension MaryBrain {

    /// The affordance act, run as though the model had called it. Returns the
    /// outcome, or nil when there was no dispatcher to run it.
    ///
    /// The whole exchange is written to history as a real Skill pair — an
    /// assistant turn holding the invocation and a `.skillResult` turn holding
    /// the summary. Anything less would leave the next turn believing nothing
    /// ran, which is the state that produced the second half of this bug.
    func dispatchAffordanceAct(
        goal: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async -> SkillOutcome? {
        guard let dispatcher else { return nil }
        let skillName = "act_on_screen"
        let argumentsJSON = (try? JSONSerialization.data(
            withJSONObject: ["goal": goal], options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
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

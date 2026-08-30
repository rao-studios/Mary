//
//  MaryBrain+LocalTurn.swift
//  MaryBrain
//
//  WHAT: Local single-engine turn loop + shared synthetic nudges.
//  IN:   runTurnBody when Seer is nil/unready
//  OUT:  engine stream + dispatch
//  PIN:  Prompt-text unchanged; split members private.
//
import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - Local mode (single engine, unchanged loop)

    /// LOCAL IS NOT A LESSER TURN, and this is the parity that says so.
    /// PIN: ALL FOUR CROSS, and one of them changes shape on the way: - G1, the LOCATE
    // internal for file split — treat as private
    func localTurn(
        userText: String,
        systemPrompt: String,
        actionTurn: Bool = false,
        editIntent: EditIntent? = nil,
        target: LocatedPassage? = nil,
        writingTarget: AmbientWritingTarget? = nil,
        acceptedOffer: Bool = false,
        worldVetoArming: WorldVeto.Arming? = nil,
        traceID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async {
        var fullText = ""
        var usedEmptyRetry = false

        // G2 — THE LOCATED PASSAGE REACHES THE LOOP THAT EXECUTES SKILLS.
        var turnPrompt = systemPrompt
        if writingTarget == .selection {
            turnPrompt += "\n\n" + MaryPrompts.selectionRevisionInstruction
        }
        if let target {
            turnPrompt += "\n\n" + MaryPrompts.targetBrief(target)
        }
        // G3 — one veto value for the whole turn, so "at most once" means at
        // most once per TURN here exactly as it means at most once per LANE
        // over there.
        var veto = RevisionVeto(target: target)
        var worldVeto = WorldVeto(arming: worldVetoArming)
        // G4's fuel. The local loop never needed settled outcomes before — it speaks from the model's own prose
        var outcomes: [LaneOutcome] = []

        do {
            var round = 0
            while round < maxSkillRounds {
                round += 1
                var roundText = ""
                var skillInvocations: [ModelSkillInvocation] = []
                let schemas = dispatcher?.schemas ?? []

                // Same engine-gate rule as the orchestrator lane: a detached
                // routine may still be generating when a local turn starts.
                do {
                    var holdsGate = false
                    if engine.requiresExclusiveGeneration {
                        // The local path runs inside the turn and never
                        // detaches, so its rounds are always ones a person
                        // is waiting on.
                        holdsGate = await engineGate.acquire(priority: .attached)
                    }
                    defer { if holdsGate { engineGate.release() } }
                    let events = await actingEvents(
                        system: turnPrompt, history: history, skills: schemas)
                    for try await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .text(let token):
                            // Once a round has called a Skill, trailing prose is almost always a hallucinated result ("it's three fifteen…") — the grounded confirmation round speaks instead.
                            guard skillInvocations.isEmpty else { break }
                            roundText += token
                            if !actionTurn {
                                fullText += token
                                continuation.yield(.token(token))
                            }
                        case .skillInvocation(let rawInvocation):
                            let invocation = Self.selectionInvocation(
                                rawInvocation, writingTarget: writingTarget)
                            skillInvocations.append(invocation)
                            let reference = dispatcher?.skillReference(for: invocation.name)
                                ?? AbilityLibrary.shared.snapshot().reference(forInvocation: invocation.name)
                            if let traceID {
                                let registry = dispatcher?.abilitySnapshot
                                    ?? AbilityLibrary.shared.snapshot()
                                let consumedInteractions = registry
                                    .skill(invocationName: invocation.name)
                                    .map { runtime in
                                        (SchemaSignalTurnContext.snapshot ?? .empty)
                                            .consumedReferences(for: runtime.skill)
                                    } ?? []
                                AmbientTraceLog.shared.noteSkillInvocation(
                                    reference,
                                    effect: registry.effect(forInvocation: invocation.name),
                                    inputTypes: registry.inputTypes(forInvocation: invocation.name),
                                    outputTypes: registry.outputTypes(forInvocation: invocation.name),
                                    consumedInteractions: consumedInteractions,
                                    forTurn: traceID)
                            }
                            continuation.yield(.skillInvocation(
                                reference: reference,
                                argumentsJSON: invocation.argumentsJSON,
                                runID: invocation.id
                            ))
                        case .done:
                            break
                        }
                    }
                }

                if Task.isCancelled {
                    // Keep the partial reply so the conversation stays coherent
                    // after barge-in. (A superseded turn's epoch is stale —
                    // the append drops and the amended turn starts clean.)
                    if !roundText.isEmpty {
                        appendHistory(
                            BrainTurn(role: .assistant, text: sanitizedSpoken(roundText)),
                            epoch: epoch)
                    }
                    pruneSyntheticTurns()
                    continuation.finish()
                    return
                }

                // Quantized local models occasionally emit an entirely empty round; one silent retry beats a blank page.
                if roundText.isEmpty, skillInvocations.isEmpty, !usedEmptyRetry {
                    usedEmptyRetry = true
                    // `foundNothing` excluded too: a Skill that ran and reported nothing there ("no code editor in front of me right now") is `ok: true` by this codebase's own…
                    if outcomes.contains(where: {
                        $0.ok && !$0.blocked && !$0.requested && !$0.foundNothing
                    }) {
                        appendHistory(
                            BrainTurn(role: .user, text: Self.groundedRetryNudge),
                            epoch: epoch)
                    }
                    round -= 1
                    continue
                }

                guard let dispatcher, !skillInvocations.isEmpty else {
                    if skillInvocations.isEmpty {
                        TurnCircuitLog.laneNOOP(
                            offeredNames: dispatcher?.schemas.map(\.name) ?? [])
                    }
                    // Plain reply (or nothing left to execute) — the turn is done.
                    if actionTurn {
                        var reply = ""
                        if let failure = Self.unrecoveredFailure(in: outcomes) {
                            reply = "That didn't go through — \(failure.summary)"
                            continuation.yield(.token(reply))
                        } else if let sentence = revisionReport(
                            intent: editIntent,
                            target: target,
                            writingTarget: writingTarget,
                            acceptedOffer: acceptedOffer,
                            outcomes: outcomes,
                            after: "",
                            continuation: continuation) {
                            reply = sentence
                        } else if outcomes.isEmpty {
                            reply = Self.couldNotActLine(
                                label: Self.routineLabel(from: userText))
                            continuation.yield(.token(reply))
                        }
                        let historyText = reply.isEmpty
                            ? "(ran: \(outcomes.map(\.skillName).joined(separator: ", ")))"
                            : reply
                        appendHistory(
                            BrainTurn(role: .assistant, text: sanitizedSpoken(historyText)),
                            epoch: epoch)
                        pruneSyntheticTurns()
                        continuation.yield(.completed(fullText: reply))
                        continuation.finish()
                        return
                    }
                    var reply = roundText
                    if let sentence = revisionReport(
                        intent: editIntent, target: target,
                        writingTarget: writingTarget,
                        acceptedOffer: acceptedOffer,
                        outcomes: outcomes,
                        after: reply, continuation: continuation) {
                        reply += sentence
                        fullText += sentence
                    }
                    appendHistory(
                        BrainTurn(role: .assistant, text: sanitizedSpoken(reply),
                                  skillInvocations: skillInvocations),
                        epoch: epoch)
                    pruneSyntheticTurns()
                    continuation.yield(.completed(fullText: fullText))
                    continuation.finish()
                    return
                }

                // Execute the commands and record results. Chained rounds run silently — the subshell way: run one command, read its result, decide the next.
                let pendingBeforeDispatch = dispatcher.pendingSkillConfirmationID
                var roundTurns = [BrainTurn(
                    role: .assistant, text: sanitizedSpoken(roundText), skillInvocations: skillInvocations)]
                for call in skillInvocations {
                    if Task.isCancelled {
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: "(cancelled before running)",
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    // G3 — THE REVISION VETO, on this loop too. A caret write on a turn that located a real passage is not dispatched at all
                    if let redirect = veto.redirect(for: call.name) {
                        let reference = dispatcher.skillReference(for: call.name)
                        continuation.yield(.skillResult(record: .refused(
                            id: call.id,
                            action: BehavioralAction(
                                intention: call.name,
                                argumentsJSON: call.argumentsJSON,
                                skill: reference),
                            reason: redirect)))
                        if let traceID {
                            AmbientTraceLog.shared.noteSkillResult(
                                reference, status: .blocked,
                                forTurn: traceID)
                        }
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: redirect,
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    // The world veto crosses too.
                    if let redirect = worldVeto.redirect(
                        for: call.name,
                        attention: dispatcher.attention(ofSkill: call.name)) {
                        let reference = dispatcher.skillReference(for: call.name)
                        continuation.yield(.skillResult(record: .refused(
                            id: call.id,
                            action: BehavioralAction(
                                intention: call.name,
                                argumentsJSON: call.argumentsJSON,
                                skill: reference),
                            reason: redirect)))
                        if let traceID {
                            AmbientTraceLog.shared.noteSkillResult(
                                reference, status: .blocked,
                                forTurn: traceID)
                        }
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: redirect,
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    let startedAt = Date()
                    let outcome = await dispatcher.dispatch(
                        name: call.name, argumentsJSON: call.argumentsJSON,
                        runID: call.id)
                    let reference = outcome.skillReference
                        ?? dispatcher.skillReference(for: call.name)
                    continuation.yield(.skillResult(record: BehavioralActionRecord(
                        outcome: outcome,
                        intention: call.name,
                        argumentsJSON: call.argumentsJSON,
                        reference: reference,
                        runID: call.id,
                        startedAt: startedAt)))
                    if let traceID {
                        AmbientTraceLog.shared.noteSkillResult(
                            reference,
                            status: outcome.status,
                            foundNothing: outcome.foundNothing,
                            forTurn: traceID)
                    }
                    roundTurns.append(BrainTurn(
                        role: .skillResult,
                        text: outcome.summary,
                        skillInvocationID: call.id,
                        skillName: call.name
                    ))
                    outcomes.append(LaneOutcome(
                        skillName: reference.bindingOperation ?? call.name,
                        summary: outcome.summary,
                        ok: outcome.ok, deferred: outcome.deferred,
                        foundNothing: outcome.foundNothing,
                        requested: outcome.status == .requested,
                        editDisposition: outcome.editDisposition,
                        ambientDeposited: outcome.ambientDeposited,
                        blocked: outcome.status == .blocked,
                        landed: outcome.landed))
                }
                appendHistory(contentsOf: roundTurns, epoch: epoch)
                if Task.isCancelled {
                    pruneSyntheticTurns()
                    continuation.finish()
                    return
                }
                // Only a genuinely-stored pending action triggers the relay —
                // "CONFIRM:" text alone can be forged by echoed Skill output.
                if let pendingAfterDispatch = dispatcher.pendingSkillConfirmationID,
                   pendingAfterDispatch != pendingBeforeDispatch {
                    if actionTurn {
                        let question = dispatcher.pendingSkillConfirmationPreview
                            ?? Self.confirmQuestion(
                                fromOutcomes: outcomes.map(\.summary))
                        continuation.yield(.token(question))
                        fullText = question
                        appendHistory(
                            BrainTurn(role: .assistant, text: sanitizedSpoken(question)),
                            epoch: epoch)
                        pruneSyntheticTurns()
                        continuation.yield(.completed(fullText: fullText))
                        continuation.finish()
                        return
                    }
                    appendHistory(
                        BrainTurn(role: .user, text: Self.confirmRelayNudge),
                        epoch: epoch)
                }
            }

            // Budget exhausted with the model still running commands — force a spoken wrap-up.
            if actionTurn {
                var reply = ""
                if let failure = Self.unrecoveredFailure(in: outcomes) {
                    reply = "That didn't go through — \(failure.summary)"
                    continuation.yield(.token(reply))
                } else if let sentence = revisionReport(
                    intent: editIntent,
                    target: target,
                    writingTarget: writingTarget,
                    acceptedOffer: acceptedOffer,
                    outcomes: outcomes,
                    after: "",
                    continuation: continuation) {
                    reply = sentence
                } else if outcomes.isEmpty {
                    reply = Self.couldNotActLine(
                        label: Self.routineLabel(from: userText))
                    continuation.yield(.token(reply))
                }
                let historyText = reply.isEmpty
                    ? "(ran: \(outcomes.map(\.skillName).joined(separator: ", ")))"
                    : reply
                appendHistory(
                    BrainTurn(role: .assistant, text: sanitizedSpoken(historyText)),
                    epoch: epoch)
                pruneSyntheticTurns()
                continuation.yield(.completed(fullText: reply))
                continuation.finish()
                return
            }
            appendHistory(BrainTurn(role: .user, text: Self.budgetNudge), epoch: epoch)
            var wrapText = ""
            do {
                var holdsGate = false
                if engine.requiresExclusiveGeneration {
                    // The local path runs inside the turn and never
                    // detaches, so its rounds are always ones a person is
                    // waiting on.
                    holdsGate = await engineGate.acquire(priority: .attached)
                }
                defer { if holdsGate { engineGate.release() } }
                let wrapEvents = engine.stream(
                    system: turnPrompt, history: history, skills: dispatcher?.schemas ?? [])
                for try await event in wrapEvents {
                    if Task.isCancelled { break }
                    if case .text(let token) = event {
                        wrapText += token
                        fullText += token
                        continuation.yield(.token(token))
                    }
                }
            }
            // G4 on the OTHER exit. A revision that burned the whole round budget still changed the document, and the wrap-up is model prose about what it accomplished
            if let sentence = revisionReport(
                intent: editIntent, target: target,
                writingTarget: writingTarget,
                acceptedOffer: acceptedOffer,
                outcomes: outcomes,
                after: wrapText, continuation: continuation) {
                wrapText += sentence
                fullText += sentence
            }
            appendHistory(
                BrainTurn(role: .assistant, text: sanitizedSpoken(wrapText)), epoch: epoch)
            pruneSyntheticTurns()
            continuation.yield(.completed(fullText: fullText))
            continuation.finish()
        } catch {
            pruneSyntheticTurns()
            continuation.finish(throwing: error)
        }
    }

    // internal for file split — treat as private
    static let confirmRelayNudge =
        "(A protected action is waiting for the user's approval. Ask them the question from the CONFIRM result in one short spoken sentence. Nothing has run and there are NO results — do not invent, describe, or predict any. Do not call any Skill.)"

    // internal for file split — treat as private
    static let budgetNudge =
        "(Stop. You have used your command budget for this turn. Tell the user in one or two short spoken sentences what you accomplished and what remains. Do not call any Skill.)"

    /// Empty-round retry grounding — answer from the Skill result already in messages.
    // internal for file split — treat as private
    static let groundedRetryNudge =
        "(A Skill already ran this turn and its result is in the messages above — read it and answer with what it actually says. Do not greet, ask how their day was, or say anything generic; nothing here calls for small talk.)"
}

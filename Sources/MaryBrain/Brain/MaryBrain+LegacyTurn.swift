//
//  MaryBrain+LegacyTurn.swift
//  MaryBrain
//
//  Legacy mode, moved out of MaryBrain.swift: the single-engine
//  `legacyTurn` loop (whole, verbatim) and the two synthetic nudges it and
//  the orchestrator share (`confirmRelayNudge`, `budgetNudge`).
//
//  Moved verbatim; no behavior change, no prompt-text change. Depends on
//  the internal-for-split promotions of the core file's stored turn state;
//  treat all of them as private.
//

import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - Legacy mode (single engine, unchanged loop)

    /// LEGACY IS NOT A LESSER TURN, and this is the parity that says so.
    ///
    /// THE FAILURE THIS FIXES (confirmed by the phase's own gate): every one of
    /// G1–G4 lived below `runTurn`'s `guard seerReady`, so the whole revision
    /// contract evaporated the moment Seer was unreachable — a dropped network,
    /// an expired token, or simply the local-MLX configuration, none of which
    /// are edge cases. On those turns "replace the Purpose section with the
    /// tighter version" reached the Skill loop as a bare imperative with nothing
    /// located in it and typed at the caret, exactly as shipped. A gate that
    /// only holds while a network is up is not a gate.
    ///
    /// ALL FOUR CROSS, and one of them changes shape on the way:
    /// - G1, the LOCATE, happens in `runTurn` above the guard so both loops are
    ///   fed by one call. The other half of G1 — fetch-first's `readNamedPart`
    ///   — deliberately does NOT cross, and that is a real difference rather
    ///   than an omission: fetch-first exists because Lane A speaks from a
    ///   message snapshot the Skill lane can never reach, and THERE IS NO LANE A
    ///   HERE. One engine holds the history, the skills and the voice at once,
    ///   so it can simply read for itself and then speak — pre-reading for it
    ///   would be latency buying nothing.
    /// - G2 appends the same `targetBrief` to the same kind of prompt.
    /// - G3 is the same `RevisionVeto` value, not a second copy of it.
    /// - G4 is the same `revisionReport`, yielded onto whatever prose the
    ///   single engine produced.
    // internal for file split — treat as private
    func legacyTurn(
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
        // LAST in the prompt, and after nothing else, because `targetBrief`
        // ends on the passage's own words: doctrine printed after an excerpt
        // gets read as part of the excerpt. Turn-scoped — it never enters
        // `history`, so it is spent on this turn and gone.
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
        // G4's fuel. The legacy loop never needed settled outcomes before —
        // it speaks from the model's own prose — so this collects the same
        // `LaneOutcome` values the orchestrator lane does, for the same
        // consumer.
        var outcomes: [LaneOutcome] = []

        do {
            var round = 0
            while round < maxSkillRounds {
                round += 1
                var roundText = ""
                var skillInvocations: [ModelSkillInvocation] = []
                let schemas = dispatcher?.schemas ?? []

                // Same engine-gate rule as the orchestrator lane: a detached
                // routine may still be generating when a legacy turn starts.
                do {
                    var holdsGate = false
                    if engine.requiresExclusiveGeneration {
                        holdsGate = await engineGate.acquire()
                    }
                    defer { if holdsGate { engineGate.release() } }
                    let events = engine.stream(system: turnPrompt, history: history, skills: schemas)
                    for try await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .text(let token):
                            // Once a round has called a Skill, trailing prose is
                            // almost always a hallucinated result ("it's three
                            // fifteen…") — the grounded confirmation round speaks
                            // instead.
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

                // Quantized local models occasionally emit an entirely empty
                // round; one silent retry beats a blank page.
                if roundText.isEmpty, skillInvocations.isEmpty, !usedEmptyRetry {
                    usedEmptyRetry = true
                    round -= 1
                    continue
                }

                guard let dispatcher, !skillInvocations.isEmpty else {
                    // Plain reply (or nothing left to execute) — the turn is done.
                    //
                    // G4 — A REVISION REPORTS ITSELF HERE TOO. This is the
                    // legacy loop's ordinary exit: earlier rounds ran the edit,
                    // this round is the model finally speaking. The sentence
                    // goes onto BOTH accumulations — `roundText` is what
                    // history keeps, `fullText` is what `.completed` carries —
                    // because in this loop the two are separate variables where
                    // `seerTurn` has only `spokenText`.
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

                // Execute the commands and record results. Chained rounds run
                // silently — the subshell way: run one command, read its
                // result, decide the next. A CONFIRM result is the exception:
                // the model must relay the question and stop. The round's
                // turns buffer locally and land as ONE batch so an epoch flip
                // can never orphan a Skill pair.
                // Do not confuse a still-parked action from a prior turn with
                // a confirmation requested by one of this round's calls.
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
                    // G3 — THE REVISION VETO, on this loop too. A caret write
                    // on a turn that located a real passage is not dispatched
                    // at all; the synthetic result names the binding and the
                    // handle to re-plan from. Not an outcome (nothing ran), and
                    // the Skill TURN is still appended so the tool_use /
                    // tool_result pairing survives into the next round.
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
                        world: dispatcher.world(ofSkill: call.name)) {
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
                        name: call.name, argumentsJSON: call.argumentsJSON)
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

            // Budget exhausted with the model still running commands — force a
            // spoken wrap-up. Schemas are still passed (the Anthropic API
            // requires `skills` when history contains tool_use blocks), but any
            // Skill calls the model attempts now are dropped, not executed.
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
                    holdsGate = await engineGate.acquire()
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
            // G4 on the OTHER exit. A revision that burned the whole round
            // budget still changed the document, and the wrap-up is model prose
            // about what it accomplished — the one thing that may not be
            // trusted to state the edges of the passage it replaced.
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
}

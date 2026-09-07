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
        /// THE TURN'S ROUTE, WHOLE — same parity as `seerTurn`: the shape of this
        /// turn was decided once, and local mode reads that decision rather than
        /// being handed a re-spelled copy of its parts.
        route: AmbientRoute,
        target: LocatedPassage? = nil,
        acceptedOffer: Bool = false,
        worldVetoArming: WorldVeto.Arming? = nil,
        traceID: UUID? = nil,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async {
        let actionTurn = route.isActionTurn
        let editIntent = route.verdicts.editIntent
        let writingTarget = route.writingTarget
        // ONE LESSON PER LANE, from the words that started it. Built here so a
        // multi-round turn cannot teach the router three different things, and
        // so the query is this turn's utterance rather than whatever the
        // process-wide routing query says by the time a round lands.
        let routingHabitGrant = RoutingHabitRecordingContext.grant(
            lane: .model, query: userText, route: route.intent)
        var fullText = ""
        var usedEmptyRetry = false
        // ONE EXTRA ROUND ACROSS BOTH RUNGS, the way the orchestrator lane latches it:
        // a turn may be nudged once, not once per reason.
        var usedContinuation = false
        // The screen's offer, when a rung named one — read again at the deterministic
        // press so the score is the one that was just measured.
        var affordanceOffer: AffordanceCandidate?

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
        var repeatedFailedCall = false

        do {
            var round = 0
            while round < maxSkillRounds {
                round += 1
                var roundText = ""
                var skillInvocations: [ModelSkillInvocation] = []
                // One projection per round, as in the orchestrator lane.
                let roundProjection = dispatcher?.projectRoster()
                let schemas = roundProjection?.schemas ?? []

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
                    // LOCAL IS NOT A LESSER TURN — the rungs the orchestrator lane has
                    // are here too. Without them a local model's turn ends politely on
                    // work it only half did, and the receipts (`landed`) that the
                    // browsing lane spent its whole design earning are read by nobody.
                    //
                    // Only read or prepared a surface, on a turn that asked for
                    // something to be DONE — say so once and let it finish.
                    //
                    // PIN: GATED ON `actionTurn` ALONE, narrower than the orchestrator's
                    // wider "implies action" reading (edit intent or a named transform).
                    // A non-action local turn streams its prose live as the tokens
                    // arrive (see the `.text` case above), so continuing after it spoke
                    // would say the same thing twice — which is not a risk the
                    // orchestrator lane runs, because it buffers into `laneHistory`.
                    if let dispatcher, !usedContinuation, actionTurn,
                       !outcomes.isEmpty,
                       !outcomes.contains(where: \.landed),
                       outcomes.allSatisfy({
                           dispatcher.isReadOnly($0.skillName)
                               || dispatcher.isNonEffectful($0.skillName)
                               || dispatcher.preparesSurface($0.skillName)
                       }) {
                        usedContinuation = true
                        appendHistory(
                            BrainTurn(role: .user, text: MaryPrompts.continuationNudge),
                            epoch: epoch)
                        Self.laneLog.info("local turn only read or prepared on an acting turn — continuing once")
                        continue
                    }
                    // Nothing ran at all, and the screen is already offering something
                    // that would serve. Name it once; the press, if it comes, is below.
                    if !usedContinuation, actionTurn, outcomes.isEmpty,
                       let offer = AffordanceProbe.candidate(for: userText),
                       !offer.labels.isEmpty {
                        usedContinuation = true
                        affordanceOffer = offer
                        appendHistory(
                            BrainTurn(
                                role: .user,
                                text: MaryPrompts.affordanceNudge(labels: offer.labels)),
                            epoch: epoch)
                        Self.laneLog.info("local turn NOOPed while the screen offered a control — naming it once")
                        continue
                    }

                    if skillInvocations.isEmpty {
                        TurnCircuitLog.laneNOOP(
                            offeredNames: Array(roundProjection?.names ?? []))
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
                            // AN IGNORED INSTRUCTION GETS REPLACED BY A MECHANISM. The
                            // model was told what the screen offers and still ran
                            // nothing; if one control answers the goal confidently
                            // enough, press it rather than report a failure. Same rung,
                            // same floor and the same `act_on_screen` the Seer turn
                            // uses — it can do nothing the model could not have done.
                            let offer = affordanceOffer
                                ?? AffordanceProbe.candidate(for: userText)
                            let acted = offer.map {
                                $0.score >= AffordanceProbe.confidentFloor
                            } == true
                                ? await dispatchAffordanceAct(
                                    goal: userText, continuation: continuation, epoch: epoch)
                                : nil
                            if let acted {
                                // Silent on success, spoken on failure — the
                                // action-turn rhythm, unchanged.
                                if !acted.ok {
                                    reply = acted.summary
                                    continuation.yield(.token(reply))
                                }
                            } else {
                                reply = Self.couldNotActLine(
                                    label: Self.routineLabel(from: userText))
                                continuation.yield(.token(reply))
                            }
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
                    // A QUESTION NEVER ENDS IN SILENCE.
                    //
                    // PIN: THE READ RAN; ONLY THE SENTENCE ABOUT IT IS MISSING.
                    // A non-action turn streams the model's prose as it arrives,
                    // so an empty round here means the model read the page (or
                    // the buffer) and then said nothing — and this exit would
                    // complete with an empty `fullText`, leaving the person
                    // looking at "Listening" with their question unanswered.
                    // The passage is in hand and is the honest answer, so it is
                    // spoken rather than dropped. The one round the empty-retry
                    // above already spent is what makes this the last resort
                    // rather than the first.
                    if fullText.isEmpty, reply.isEmpty, !outcomes.isEmpty {
                        let readBack = Self.spokenReadBack(outcomes: outcomes)
                        if !readBack.isEmpty {
                            reply = readBack
                            fullText += readBack
                            continuation.yield(.token(readBack))
                            Self.laneLog.info(
                                "local turn read and said nothing — speaking the passage")
                            readLedger.record(ReadDelivery(
                                route: .spokenDetached,
                                detail: outcomes.map(\.skillName).joined(separator: ", "),
                                characters: readBack.count))
                        }
                    }
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
                let outcomesBefore = outcomes.count
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
                    // THE SAME CALL THAT JUST FAILED IS NOT TRIED AGAIN, and one that
                    // ran unproven waits for a look. See MaryBrain+RepeatGuard.
                    if let prior = Self.alreadyFailed(call, in: outcomes) {
                        let line = Self.repeatedFailureLine(call.name, prior: prior)
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: line,
                            skillInvocationID: call.id, skillName: call.name))
                        repeatedFailedCall = true
                        Self.laneLog.info("repeat of a failed call refused — the turn wraps up")
                        continue
                    }
                    if Self.alreadyRanUnproven(
                        call, in: outcomes, isRead: dispatcher.isReadOnly) != nil {
                        let line = Self.unprovenRepeatLine(call.name)
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: line,
                            skillInvocationID: call.id, skillName: call.name))
                        Self.laneLog.info("repeat of an unproven act held — look first")
                        continue
                    }
                    let startedAt = Date()
                    let outcome = await RoutingHabitRecordingContext.withGrant(routingHabitGrant) {
                        await dispatcher.dispatch(
                            name: call.name, argumentsJSON: call.argumentsJSON,
                            runID: call.id)
                    }
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
                        outcome: outcome,
                        invocation: call.name,
                        argumentsJSON: call.argumentsJSON))
                }
                appendHistory(contentsOf: roundTurns, epoch: epoch)
                if Task.isCancelled {
                    pruneSyntheticTurns()
                    continuation.finish()
                    return
                }
                // A QUESTION TO THE PERSON ENDS THE LANE — spoken as a question,
                // never as "that didn't go through". See the orchestrator lane.
                if let asked = outcomes[outcomesBefore...].first(where: \.asksThePerson) {
                    let question = asked.summary
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
                if repeatedFailedCall { break }
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
                if let asked = Self.openQuestion(in: outcomes) {
                    reply = asked.summary
                    continuation.yield(.token(reply))
                } else if let failure = Self.unrecoveredFailure(in: outcomes) {
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

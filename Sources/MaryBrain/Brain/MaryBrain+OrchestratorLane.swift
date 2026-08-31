//
//  MaryBrain+OrchestratorLane.swift
//  MaryBrain
//
//  WHAT: Silent Skill loop (Lane B) — rounds, dispatch, no voice.
//  IN:   seerTurn / localTurn
//  OUT:  OrchestratorLaneResult
//
import MaryVoice
import Foundation
import os

extension MaryBrain {

    /// Skill loop with voice removed — rounds dispatch as in legacy; prose kept for offline fallback.
    // internal for file split — treat as private
    func runOrchestratorLane(
        userText: String,
        systemPrompt: String,
        seed: [BrainTurn],
        emitter: LaneEmitter,
        target: LocatedPassage? = nil,
        worldVetoArming: WorldVeto.Arming? = nil,
        /// Stage-0 observation only — see `seerTurn`.
        traceID: UUID? = nil,
        /// Classifier verdicts, passed rather than re-derived — used only for "did they ask for a change?"
        actionTurn: Bool = false,
        editIntent: EditIntent? = nil,
        /// Route shape — first reader of the route in this tree, not only a recorder.
        routeIntent: AmbientIntent? = nil,
        writingTarget: AmbientWritingTarget? = nil,
        /// Pre-lane look fired and missed its budget. Voice already promised a look.
        lookUnderway: Bool = false,
        /// Pre-lane look already answered this turn. Look-first nudge must not fire.
        servedByPreLook: Bool = false,
        /// Pre-lane READ already answered this turn (a buffer, a document, a
        /// selection — not a look). Voice already holds their work; this
        /// lane's job is only what is NOT in that passage.
        servedByRead: Bool = false,
        /// Whether the turn is still waiting on this lane. Nil for probes and the legacy path.
        attachment: LaneAttachment? = nil
    ) async -> OrchestratorLaneResult {
        var result = OrchestratorLaneResult()
        guard let dispatcher else { return result }
        // G2 — located passage reaches the lane that executes Skills.
        var orchestratorPrompt = systemPrompt + "\n\n" + MaryPrompts.orchestratorAddendum
        if writingTarget == .selection {
            orchestratorPrompt += "\n\n" + MaryPrompts.selectionRevisionInstruction
        }
        if let target {
            orchestratorPrompt += "\n\n" + MaryPrompts.targetBrief(target)
        }
        // Pre-look already served — note rides the same prompt seam as the passage.
        // A read outranks a look: the voice holds actual content, not a glance.
        if servedByRead {
            orchestratorPrompt += "\n\n" + MaryPrompts.servedByReadNote
        } else if servedByPreLook {
            orchestratorPrompt += "\n\n" + MaryPrompts.servedByLookNote
        }
        var laneHistory = seed

        // G3 — revision veto. Bounds and judgement live in `RevisionVeto`; this is plumbing.
        var veto = RevisionVeto(target: target)
        // World veto — armed by a revise-cue with a live ledger referent, never by the exemplar.
        var worldVeto = WorldVeto(arming: worldVetoArming)

        var usedEmptyRetry = false
        // Whether this turn asked for a change (action, edit intent, or transform vocabulary).
        let impliesAction = actionTurn || editIntent != nil
            || AmbientRanker.namesTransform(userText)
        var usedContinuation = false
        var round = 0
        do {
            while round < maxSkillRounds {
                round += 1
                var roundText = ""
                var skillInvocations: [ModelSkillInvocation] = []

                // Generation rounds serialize only for engines that need it (local MLX).
                let roundStart = DispatchTime.now()
                var gateWaitMs: UInt64 = 0
                let queueDepth = engineGate.waiterCount
                do {
                    var holdsGate = false
                    if engine.requiresExclusiveGeneration {
                        let attached = attachment?.isAttached ?? true
                        if !attached, engineGate.waiterCount >= Self.maxDetachedRoutines {
                            Self.laneLog.info(
                                "detached lane dropped — engine gate already at cap")
                            break
                        }
                        // Live turn precedes background; once detached it joins them.
                        holdsGate = await engineGate.acquire(
                            priority: attached ? .attached : .detached)
                        gateWaitMs = Self.elapsedMs(since: roundStart)
                    }
                    defer { if holdsGate { engineGate.release() } }
                    let events = await actingEvents(
                        system: orchestratorPrompt, history: laneHistory,
                        skills: dispatcher.schemas)
                    for try await event in events {
                        if Task.isCancelled { break }
                        switch event {
                        case .text(let token):
                            guard skillInvocations.isEmpty else { break }
                            roundText += token
                        case .skillInvocation(let rawInvocation):
                            let invocation = Self.selectionInvocation(
                                rawInvocation, writingTarget: writingTarget)
                            skillInvocations.append(invocation)
                            // Trace what the model reached for vs. what a narrowed roster would hide.
                            let reference = dispatcher.skillReference(for: invocation.name)
                            if let traceID {
                                let consumedInteractions = dispatcher.abilitySnapshot
                                    .skill(invocationName: invocation.name)
                                    .map { runtime in
                                        (SchemaSignalTurnContext.snapshot ?? .empty)
                                            .consumedReferences(for: runtime.skill)
                                    } ?? []
                                AmbientTraceLog.shared.noteSkillInvocation(
                                    reference,
                                    effect: dispatcher.abilitySnapshot.effect(
                                        forInvocation: invocation.name),
                                    inputTypes: dispatcher.abilitySnapshot.inputTypes(
                                        forInvocation: invocation.name),
                                    outputTypes: dispatcher.abilitySnapshot.outputTypes(
                                        forInvocation: invocation.name),
                                    consumedInteractions: consumedInteractions,
                                    forTurn: traceID)
                            }
                            emitter.emitSkillInvocation(
                                reference: reference,
                                argumentsJSON: invocation.argumentsJSON,
                                runID: invocation.id
                            )
                        case .done:
                            break
                        }
                    }
                }

                let generateMs = Self.elapsedMs(since: roundStart) - gateWaitMs
                let dispatchStart = DispatchTime.now()
                let callCount = skillInvocations.count
                // Defer the round log — early `continue`/`return` is the line worth seeing.
                defer {
                    let line = "round \(round) — queued \(gateWaitMs)ms"
                        + " (depth \(queueDepth)), generated \(generateMs)ms,"
                        + " dispatched \(Self.elapsedMs(since: dispatchStart))ms,"
                        + " calls=\(callCount),"
                        + " attached=\(attachment?.isAttached ?? true),"
                        + " trace=\(traceID?.uuidString.prefix(8) ?? "-")"
                    Self.laneLog.info("\(line, privacy: .public)")
                }

                if Task.isCancelled { return result }

                if roundText.isEmpty, skillInvocations.isEmpty, !usedEmptyRetry {
                    usedEmptyRetry = true
                    round -= 1
                    continue
                }

                guard !skillInvocations.isEmpty else {
                    if !usedContinuation, writingTarget == .selection {
                        usedContinuation = true
                        orchestratorPrompt += "\n\n" + MaryPrompts.selectionRevisionNudge
                        Self.laneLog.info("selected-text revision did not dispatch — retrying once")
                        continue
                    }
                    // Staging failed on an acting turn — one bounded continuation.
                    // PIN: Conditions are about the shape of the work, not the sentence.
                    if !usedContinuation,
                       let failed = result.outcomes.last(where: {
                           !$0.ok && dispatcher.preparesSurface($0.skillName)
                       }),
                       impliesAction {
                        usedContinuation = true
                        laneHistory.append(BrainTurn(
                            role: .user,
                            text: MaryPrompts.stageRecoveryNudge(
                                failedSkill: failed.skillName)))
                        Self.laneLog.info("staging failed on an acting turn — recovering once")
                        continue
                    }
                    // Only read/prepared/cognitive on an acting turn — continue once.
                    if !usedContinuation, !result.outcomes.isEmpty,
                       !result.outcomes.contains(where: \.landed),
                       result.outcomes.allSatisfy({
                           dispatcher.isReadOnly($0.skillName)
                               || dispatcher.isNonEffectful($0.skillName)
                               || dispatcher.preparesSurface($0.skillName)
                       }),
                       impliesAction {
                        usedContinuation = true
                        laneHistory.append(BrainTurn(
                            role: .user, text: MaryPrompts.continuationNudge))
                        Self.laneLog.info("lane only read/prepared on an acting turn — continuing once")
                        continue
                    }
                    // Never looked or read, on a question about their work — look once.
                    if !usedContinuation, result.outcomes.isEmpty,
                       !servedByPreLook, !servedByRead,
                       routeIntent == .perceive || lookUnderway {
                        usedContinuation = true
                        laneHistory.append(BrainTurn(
                            role: .user, text: MaryPrompts.lookFirstNudge))
                        Self.laneLog.info("lane NOOPed a question about their work — looking once")
                        continue
                    }
                    // Screen already offers a control, and nobody said so.
                    // PIN: Last escape — only after cheaper "nothing ran" readings declined.
                    if !usedContinuation, result.outcomes.isEmpty, impliesAction,
                       let offer = AffordanceProbe.candidate(for: userText),
                       !offer.labels.isEmpty {
                        usedContinuation = true
                        result.affordanceOffer = offer
                        laneHistory.append(BrainTurn(
                            role: .user,
                            text: MaryPrompts.affordanceNudge(
                                labels: offer.labels)))
                        Self.laneLog.info("lane NOOPed while the screen offered a control — naming it once")
                        continue
                    }
                    // Nothing to execute — keep prose as offline fallback for `seerTurn`.
                    TurnCircuitLog.laneNOOP(offeredNames: dispatcher.schemas.map(\.name))
                    result.text = sanitizedSpoken(roundText)
                    return result
                }

                // Skill rounds carry empty text so the tool_use → tool_result pairing survives.
                let pendingBeforeDispatch = dispatcher.pendingSkillConfirmationID
                var roundTurns = [BrainTurn(role: .assistant, text: "", skillInvocations: skillInvocations)]
                var lastOutcomes: [String] = []
                for call in skillInvocations {
                    if Task.isCancelled {
                        // Superseded mid-round — stop issuing calls; synthetic results keep the pair.
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: "(cancelled before running)",
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    // Revision veto — caret write with a located passage is not dispatched.
                    // PIN: Nothing ran, so `outcomes` must not gain a row.
                    if let redirect = veto.redirect(for: call.name) {
                        let reference = dispatcher.skillReference(for: call.name)
                        emitter.emitSkillResult(.refused(
                            id: call.id,
                            action: BehavioralAction(
                                intention: call.name,
                                argumentsJSON: call.argumentsJSON,
                                skill: reference),
                            reason: redirect))
                        if let traceID {
                            AmbientTraceLog.shared.noteSkillResult(
                                reference, status: .blocked,
                                forTurn: traceID)
                        }
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: redirect,
                            skillInvocationID: call.id, skillName: call.name))
                        lastOutcomes.append(redirect)
                        continue
                    }
                    // World veto — rival watched world on a writing-led turn that named none.
                    if let redirect = worldVeto.redirect(
                        for: call.name,
                        attention: dispatcher.attention(ofSkill: call.name)) {
                        let reference = dispatcher.skillReference(for: call.name)
                        emitter.emitSkillResult(.refused(
                            id: call.id,
                            action: BehavioralAction(
                                intention: call.name,
                                argumentsJSON: call.argumentsJSON,
                                skill: reference),
                            reason: redirect))
                        if let traceID {
                            AmbientTraceLog.shared.noteSkillResult(
                                reference, status: .blocked,
                                forTurn: traceID)
                        }
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: redirect,
                            skillInvocationID: call.id, skillName: call.name))
                        lastOutcomes.append(redirect)
                        continue
                    }
                    let startedAt = Date()
                    let outcome = await dispatcher.dispatch(
                        name: call.name, argumentsJSON: call.argumentsJSON,
                        runID: call.id)
                    let reference = outcome.skillReference
                        ?? dispatcher.skillReference(for: call.name)
                    emitter.emitSkillResult(BehavioralActionRecord(
                        outcome: outcome,
                        intention: call.name,
                        argumentsJSON: call.argumentsJSON,
                        reference: reference,
                        runID: call.id,
                        startedAt: startedAt))
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
                    lastOutcomes.append(outcome.summary)
                    result.outcomes.append(LaneOutcome(
                        skillName: reference.bindingOperation ?? call.name,
                        summary: outcome.summary,
                        ok: outcome.ok, deferred: outcome.deferred,
                        // The one place `foundNothing` can be lost — downstream reads it off `LaneOutcome`.
                        foundNothing: outcome.foundNothing,
                        requested: outcome.status == .requested,
                        editDisposition: outcome.editDisposition,
                        ambientDeposited: outcome.ambientDeposited,
                        blocked: outcome.status == .blocked,
                        landed: outcome.landed))
                    archive(
                        reference: reference,
                        skillName: reference.bindingOperation ?? call.name,
                        argumentsJSON: call.argumentsJSON,
                            summary: outcome.summary, userText: userText,
                            succeeded: outcome.ok,
                            deferred: outcome.deferred,
                            policy: outcome.archivePolicy)
                }
                // Lane history keeps the model's plan; shared history still does not.
                var laneRoundTurns = roundTurns
                let planned = sanitizedSpoken(roundText)
                if !planned.isEmpty {
                    laneRoundTurns[0] = BrainTurn(
                        role: .assistant, text: planned, skillInvocations: skillInvocations)
                }
                laneHistory.append(contentsOf: laneRoundTurns)
                result.laneTurns.append(contentsOf: roundTurns)

                if Task.isCancelled { return result }

                // Stored pending action only — "CONFIRM:" text can be forged by echoed Skill output.
                if let pendingAfterDispatch = dispatcher.pendingSkillConfirmationID,
                   pendingAfterDispatch != pendingBeforeDispatch {
                    // Stored preview, not a parse of the outcome text.
                    result.confirmQuestion = dispatcher.pendingSkillConfirmationPreview
                        ?? Self.confirmQuestion(fromOutcomes: lastOutcomes)
                    return result
                }
            }
        } catch {
            // Orchestration failing must never take the voice down with it.
            return result
        }
        return result
    }

    // internal for file split — treat as private
    static func selectionInvocation(
        _ invocation: ModelSkillInvocation, writingTarget: AmbientWritingTarget?
    ) -> ModelSkillInvocation {
        guard writingTarget == .selection, invocation.name == "type_at_cursor",
              let data = invocation.argumentsJSON.data(using: .utf8),
              var arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return invocation }
        arguments["mode"] = TypingMode.replaceSelection.rawValue
        guard let normalized = try? JSONSerialization.data(
            withJSONObject: arguments, options: [.sortedKeys]),
              let argumentsJSON = String(data: normalized, encoding: .utf8)
        else { return invocation }
        return ModelSkillInvocation(
            id: invocation.id, name: invocation.name, argumentsJSON: argumentsJSON)
    }

}

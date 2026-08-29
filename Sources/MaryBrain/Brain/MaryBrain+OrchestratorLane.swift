//
//  MaryBrain+OrchestratorLane.swift
//

import MaryVoice
import Foundation
import os

extension MaryBrain {

    /// Today's Skill loop with the voice removed: rounds run and dispatch
    /// exactly as in legacy mode, but round prose is captured (for offline
    /// fallback), never yielded, and never enters history — Seer's reply is
    /// the assistant turn. A CONFIRM stops the lane; the coordinator relays
    /// the question.
    ///
    /// The lane works against a PRIVATE history (`seed` + its own rounds) and
    /// never writes shared state — the coordinator batch-merges `laneTurns`
    /// at join. That keeps Skill pairs atomic under the epoch guard and lets
    /// the lane outlive the turn later (detached routines).
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
        /// The turn's two classifier verdicts, passed rather than re-derived —
        /// the lane needs them only to answer "did they ask for a change?" for
        /// the continuation below. Re-running the classifiers here would be a
        /// second copy of a judgement the turn loop already made.
        actionTurn: Bool = false,
        editIntent: EditIntent? = nil,
        /// THE ROUTE'S SHAPE, and the first thing in this tree to READ the
        /// route rather than only record it.
        ///
        /// It is used for exactly one thing — deciding whether a lane that ran
        /// NOTHING should be asked to look once more. That direction is the
        /// only one a route is allowed to move in: it may add work, never
        /// remove reach. See `docs/PROMPT-ASSEMBLY.md`.
        routeIntent: AmbientIntent? = nil,
        writingTarget: AmbientWritingTarget? = nil,
        /// The pre-lane look fired and missed its budget — the voice already
        /// PROMISED a look, so a lane that NOOPs here gets the look-first
        /// nudge even on a `.converse` route (the classifier's "that"-shapes).
        lookUnderway: Bool = false,
        /// The pre-lane look already ANSWERED this turn (its description rode
        /// `readPassages` into the voice). The lane is a backstop for
        /// ACTIONS only; the look-first nudge must not fire.
        servedByPreLook: Bool = false,
        /// Whether the turn is still waiting on this lane. Nil for callers
        /// with no turn to detach from (probes, the legacy path).
        attachment: LaneAttachment? = nil
    ) async -> OrchestratorLaneResult {
        var result = OrchestratorLaneResult()
        guard let dispatcher else { return result }
        // G2 — THE LOCATED PASSAGE REACHES THE LANE THAT EXECUTES SKILLS.
        //
        // `readPassages` goes to the SPEAKING lane's instructions; this prompt
        // is assembled from a system prompt built two hundred lines earlier in
        // the turn. So the lane that had to CHANGE the passage was the one
        // structurally guaranteed never to see it, and "replace the Purpose
        // section with the tighter version" reached the skills as a bare
        // imperative with nothing located in it.
        //
        // LAST, and after the addendum, because `targetBrief` ends on the
        // passage's own words and nothing may follow them — doctrine printed
        // after an excerpt gets read as part of the excerpt. It rides the
        // PROMPT only: it never enters `laneHistory` (below) or shared history,
        // so it is spent on this turn and gone.
        var orchestratorPrompt = systemPrompt + "\n\n" + MaryPrompts.orchestratorAddendum
        if writingTarget == .selection {
            orchestratorPrompt += "\n\n" + MaryPrompts.selectionRevisionInstruction
        }
        if let target {
            orchestratorPrompt += "\n\n" + MaryPrompts.targetBrief(target)
        }
        // THE LAYER THEY MEAN rides the same prompt seam the passage does —
        // and for a create-like turn, the exemplar rides instead: reference
        // material with an explicit "do not modify" so borrowing its colors
        // cannot become editing it.
        if servedByPreLook {
            orchestratorPrompt += "\n\n" + MaryPrompts.servedByLookNote
        }
        var laneHistory = seed

        // G3 — THE REVISION VETO. Both bounds and the judgement itself live in
        // `RevisionVeto`, which the legacy loop owns a copy of too; what stays
        // here is only this lane's plumbing (emitter, lane turns, outcomes).
        var veto = RevisionVeto(target: target)
        // Its canvas sibling, armed only by a revise-cue turn with a live
        // ledger referent — never by the exemplar.
        // And the world-boundary sibling — the backstop behind roster
        // scoping for a rival-world call that arrives anyway.
        var worldVeto = WorldVeto(arming: worldVetoArming)

        var usedEmptyRetry = false
        // Whether this turn asked for something to CHANGE, by any of the three
        // signals that already exist — the two classifiers the turn loop
        // computed, and the ambient ranker's transform vocabulary for the
        // phrasings they miss. Computed once; see the continuation below.
        let impliesAction = actionTurn || editIntent != nil
            || AmbientRanker.namesTransform(userText)
        var usedContinuation = false
        var round = 0
        do {
            while round < maxSkillRounds {
                round += 1
                var roundText = ""
                var skillInvocations: [ModelSkillInvocation] = []

                // Generation rounds serialize ONLY for engines that need it
                // (local MLX). Gating stateless HTTP engines was the latency
                // regression: a lane queued behind another round missed the
                // 250ms join grace and detached, so every fast action became
                // a routine. The gate covers ONLY the stream consumption
                // (throw-safe defer); a cancelled waiter acquires nothing.
                // THREE NUMBERS, MEASURED SEPARATELY: how long this round
                // QUEUED, how long it GENERATED, and how long its calls RAN.
                //
                // Nothing measured them before, and the split is the whole
                // diagnosis. With the local MLX engine every generation round
                // in the process serializes on `engineGate`, so five detached
                // routines are a queue up to fifty rounds deep — and a turn
                // that waits behind them misses its 250 ms join grace and
                // detaches, which adds a sixth. In the log that feedback loop
                // and a genuinely slow model look identical until the queue
                // time is split out.
                let roundStart = DispatchTime.now()
                var gateWaitMs: UInt64 = 0
                let queueDepth = engineGate.waiterCount
                do {
                    var holdsGate = false
                    if engine.requiresExclusiveGeneration {
                        // A live turn goes ahead of background rounds; once
                        // this lane detaches it takes its place among them.
                        holdsGate = await engineGate.acquire(
                            priority: (attachment?.isAttached ?? true)
                                ? .attached : .detached)
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
                            // The shadow measurement's other half: what the
                            // model actually reached for, against what a
                            // narrowed roster would have hidden. Recorded at
                            // the ASK rather than at the outcome, because a
                            // call that resolves to nothing is exactly the
                            // case worth seeing.
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
                // `defer` rather than a line after the dispatch loop: this
                // round has several `continue`s and two `return`s, and a round
                // that leaves early is exactly the one worth seeing.
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
                    // ONLY LOOKED, ON A TURN THAT ASKED FOR A CHANGE — one
                    // bounded continuation before this becomes terminal.
                    //
                    // This return is the lane's whole stopping condition, and
                    // `orchestratorAddendum` asks the model for exactly the
                    // short private note that trips it. So a compound request
                    // — find the section, then revise it — ended after the
                    // find, and nothing downstream could tell that apart from
                    // a lane that did everything: every check asks "did
                    // anything run", never "did the asked-for thing run".
                    //
                    // The three conditions are deliberately about the SHAPE OF
                    // THE WORK rather than the shape of the sentence, so this
                    // covers check-then-create and read-then-send as readily
                    // as find-then-revise:
                    //   1. something ran (a lane that ran nothing is a NOOP,
                    //      which is the addendum working correctly),
                    //   2. everything that ran was READ-ONLY, and
                    //   3. the turn implied action.
                    //
                    // `namesTransform` is the ambient ranker's own transform
                    // vocabulary — reused rather than respelled, because a
                    // second copy of "what counts as changing something" is
                    // how the two would start disagreeing.
                    // A STAGING OP FAILED on a turn whose remaining work
                    // depends on that surface (the incident's cause K:
                    // "TextEdit didn't come forward" → the lane rolled on to
                    // Pages). One bounded recovery round — raise the exact
                    // window or say honestly why the turn stops — never a
                    // silent rotation to another app.
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
                    // The predicate admits three non-delivering shapes: pure
                    // reads, COGNITIVE activations (compose_draft returns
                    // instruction, not effect — the draft still has to go
                    // somewhere), and SURFACE PREPARATION (new_pages_document
                    // staged the page; nothing is written on it yet). Each is
                    // "the first half" of a compound acting turn.
                    // NOTHING LANDED is the question this asks, and it used to
                    // answer it from the ROSTER instead of from the run: a
                    // skill declared read-only or surface-preparing was assumed
                    // not to have delivered, whatever it actually did. That
                    // assumption cycled the browser — `search_web` opened the
                    // video and was told to go and carry out the request, so it
                    // searched again and navigated off the video. An outcome
                    // that PROVED its effect now says so and the nudge stands
                    // down; everything that only read or prepared still gets
                    // its one continuation, which is the case this was built
                    // for and the reason the rest of the predicate is intact.
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
                    // NEVER LOOKED AT ALL, on a question about their own work.
                    //
                    // THE OTHER HALF OF THE SAME DEADLOCK. "What do you think
                    // about the hugging face paragraph" is an OPINION by
                    // grammar and a DOCUMENT QUESTION by meaning, and the
                    // addendum's NOOP clause used to catch it — so this lane
                    // ran nothing while the speaking lane, which holds no
                    // skills, promised "give me a moment to find it". Neither
                    // answered.
                    //
                    // `.perceive` is precisely "they are asking about what is
                    // in front of them" — deictic, or naming the world that
                    // leads. It cannot fire on conversation (`.converse`) or
                    // on a turn that already acted, and it only ever ADDS a
                    // round. The addendum above now says the same thing in
                    // prose; this is the mechanism, because in this tree a
                    // prompt line has never been sufficient on its own.
                    // `lookUnderway` joins `.perceive`: the voice has already
                    // promised a look for this very turn, so a NOOP here
                    // would leave that promise dangling. A SERVED pre-look is
                    // the opposite case — the question was answered aloud;
                    // nudging the lane to look again is how a video question
                    // went document-hunting.
                    if !usedContinuation, result.outcomes.isEmpty,
                       !servedByPreLook,
                       routeIntent == .perceive || lookUnderway {
                        usedContinuation = true
                        laneHistory.append(BrainTurn(
                            role: .user, text: MaryPrompts.lookFirstNudge))
                        Self.laneLog.info("lane NOOPed a question about their work — looking once")
                        continue
                    }
                    // THE SCREEN ALREADY OFFERS IT, and nobody said so.
                    //
                    // Last of the escapes, and deliberately last: it fires
                    // only when every cheaper reading of "nothing ran" has
                    // declined, so a turn that could be served by a declared
                    // Skill is never diverted into pressing something. What
                    // it answers is the case where no declared Skill EXISTS —
                    // "skip the ad", "make it full screen" — and the control
                    // that would do it is sitting on the page, already
                    // perceived, already named.
                    //
                    // The probe is over PUBLISHED slates only, so it can say
                    // nothing about an application no perception lane has
                    // read. That is the correct silence: an unobserved screen
                    // is not an empty one, and this rung never claims it is.
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
                    // Nothing to execute — keep the prose as offline fallback.
                    // Stripped: this text can be SPOKEN by the seerTurn
                    // fallback ladder and grounds detached follow-ups.
                    result.text = sanitizedSpoken(roundText)
                    return result
                }

                // Skill rounds carry EMPTY text: the pairing (tool_use →
                // tool_result) must survive for later rounds, but orchestrator
                // prose must never surface in spoken history — Seer's reply is
                // the only assistant voice.
                // A pending inherited from an earlier turn is context for a
                // later explicit yes/no; it is not an outcome of this round.
                // Only an identity created or replaced by one of the calls
                // below is allowed to stop the lane and surface a question.
                let pendingBeforeDispatch = dispatcher.pendingSkillConfirmationID
                var roundTurns = [BrainTurn(role: .assistant, text: "", skillInvocations: skillInvocations)]
                var lastOutcomes: [String] = []
                for call in skillInvocations {
                    if Task.isCancelled {
                        // Superseded mid-round: stop issuing calls, but keep
                        // the pair invariant — undispatched calls get a
                        // synthetic result.
                        roundTurns.append(BrainTurn(
                            role: .skillResult, text: "(cancelled before running)",
                            skillInvocationID: call.id, skillName: call.name))
                        continue
                    }
                    // THE REVISION VETO. A caret write, on a turn that has a
                    // real located passage, is not dispatched at all. The
                    // judgement (and both of its bounds) is `RevisionVeto`.
                    //
                    // NOT AN OUTCOME OF THE LANE: nothing ran, so `outcomes`
                    // must not gain a row. A vetoed call that booked itself
                    // would make an all-veto turn look like a successful action
                    // turn and settle silently — and a turn where nothing
                    // happened would report "done". The Skill TURN is still
                    // appended, because the tool_use/tool_result pairing must
                    // survive into the next round or the wire breaks.
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
                    // THE WORLD VETO — a call aimed at a rival watched world
                    // on a writing-led turn that named no such world is not
                    // dispatched; the synthetic result names the leading
                    // world's own targeted read.
                    if let redirect = worldVeto.redirect(
                        for: call.name,
                        world: dispatcher.world(ofSkill: call.name)) {
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
                        // THE ONE PLACE the flag can be lost. Everything
                        // downstream that refuses to recite a miss reads it off
                        // `LaneOutcome`; this line is the whole reason it can.
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
                // THE LANE'S OWN CONTEXT KEEPS THE MODEL'S PLAN; SHARED
                // HISTORY STILL DOES NOT.
                //
                // The empty text above is right for `result.laneTurns` — those
                // merge into spoken history and Seer's reply is the only
                // assistant voice — but `laneHistory` is the lane talking to
                // ITSELF, and stripping the prose there erased the model's own
                // commitment to a second step. On the traced failure it wrote
                // "I'll read the Implementation section now", called
                // `find_passage`, and then on round two saw an assistant turn
                // with no words in it, no plan, and no reason to continue.
                //
                // Two arrays, one round: the pairing invariant is identical in
                // both, only the assistant turn's text differs.
                var laneRoundTurns = roundTurns
                let planned = sanitizedSpoken(roundText)
                if !planned.isEmpty {
                    laneRoundTurns[0] = BrainTurn(
                        role: .assistant, text: planned, skillInvocations: skillInvocations)
                }
                laneHistory.append(contentsOf: laneRoundTurns)
                result.laneTurns.append(contentsOf: roundTurns)

                if Task.isCancelled { return result }

                // Only a genuinely-stored pending action counts — "CONFIRM:"
                // text alone can be forged by echoed Skill output. The
                // coordinator speaks the question; this lane is done.
                if let pendingAfterDispatch = dispatcher.pendingSkillConfirmationID,
                   pendingAfterDispatch != pendingBeforeDispatch {
                    // The STORED preview, not a parse of the outcome text. The
                    // summary is machine-framed ("CONFIRM: …"), and stripping
                    // the token used to leave whatever else the summary
                    // carried to be spoken verbatim. The store holds the exact
                    // question a "yes" will execute; test dispatchers without
                    // a store keep the parsing fallback.
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

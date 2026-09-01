//
//  MaryBrain+SeerTurn.swift
//  MaryBrain
//
//  WHAT: Seer-mode coordinator — dual lane, join/detach, takeover.
//  IN:   runTurnBody
//  OUT:  SeerLaneResult / LaneOutcome / OrchestratorLaneResult
//  PIN:  seerTurn moved whole; split members private.
//
import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - Seer mode (dual lane)

    // internal for file split — treat as private
    struct SeerLaneResult {
        var text = ""
        var contribution: SeerContribution?
        var autoMemory = false
        var failed = false
    }

    /// One dispatched Skill's settled outcome inside a lane. CARRIES the outcome
    /// rather than re-spelling it — restating these fields per construction site
    /// is how `foundNothing` once got dropped on the last hop.
    struct LaneOutcome: Sendable {
        /// The lane's dispatch name — the binding's operation, else the model's
        /// invocation name. The lane's own addition; not a `SkillOutcome` field.
        var skillName: String
        var outcome: SkillOutcome

        var summary: String { outcome.summary }
        var ok: Bool { outcome.ok }
        var deferred: Bool { outcome.deferred }
        /// The binding LOOKED and what was asked for is not in what it can read.
        var foundNothing: Bool { outcome.foundNothing }
        /// A CONFIRM park.
        var requested: Bool { outcome.status == .requested }
        var editDisposition: EditDisposition? { outcome.editDisposition }
        /// The read's content already lives in ambient context ("Still in hand"),
        /// so reciting its machine summary aloud is redundant. The silent-settle
        /// gate reads this.
        var ambientDeposited: Bool { outcome.ambientDeposited }
        /// A POLICY refusal (the mismatch mirror, a schema-policy denial),
        /// distinct from an adapter failure.
        var blocked: Bool { outcome.status == .blocked }
        /// The acting intent is satisfied.
        var landed: Bool { outcome.landed }
    }

    struct OrchestratorLaneResult {
        var text = ""
        /// The question of a CONFIRM the lane surfaced (already stripped of
        /// its prefix), spoken deterministically after the Seer reply.
        var confirmQuestion: String?
        /// Settled outcome per dispatch — fuel for the grounded follow-up.
        var outcomes: [LaneOutcome] = []
        /// The lane's Skill turns, buffered privately (never written to shared
        /// history mid-lane) and batch-merged at join so tool_use/tool_result
        /// pairs can never be orphaned by an epoch flip.
        var laneTurns: [BrainTurn] = []
        /// The control the screen was offering when this lane ran nothing — set by the affordance escape, and the evidence the turn-level last rung needs.
        var affordanceOffer: AffordanceCandidate?
    }

    // internal for file split — treat as private
    func seerTurn(
        userText: String,
        originUserTurnID: UUID,
        systemPrompt: String,
        /// THE TURN'S ROUTE, WHOLE. It already answers every question this used to
        /// take as a separate scalar; passing the pieces only let them disagree.
        route: AmbientRoute,
        target located: LocatedPassage? = nil,
        /// True when this turn is a synthesized accepted-offer revision —
        /// EditReport's silent-miss arm keys on it.
        acceptedOffer: Bool = false,
        /// The world-boundary backstop, armed by the turn loop from the same
        /// admission formula the roster scope uses.
        worldVetoArming: WorldVeto.Arming? = nil,
        /// Stage-0 observation only: which `AmbientTraceLog` row this turn's Skill calls belong to.
        traceID: UUID? = nil,
        seerChat: any SeerChatProviding,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async {
        let actionTurn = route.isActionTurn
        let editIntent = route.verdicts.editIntent
        let writingTarget = route.writingTarget
        let routeIntent = route.intent
        // WHERE this turn is happening, for the prose offer this reply may carry: an offer made about a manuscript must be written back into that manuscript
        let leadPlace = route.leadPlace
        // Fetch first, then speak.
        let turnStartedAt = Date()
        var readPassages: [String] = []
        if editIntent == nil, !actionTurn, let dispatcher,
           let phrase = route.verdicts.namedPart {
            // A SUSPENSION POINT before any lane exists.
            let passage = await withNanosecondBudget(Self.preReadBudgetNanoseconds) {
                await dispatcher.readNamedPart(phrase)
            }
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
                continuation.finish()
                return
            }
            if let passage {
                readPassages = [passage]
                readLedger.record(ReadDelivery(
                    route: .prefetched, detail: "\"\(phrase)\"",
                    characters: passage.count))
            }
        }

        // Fetch-first: highlight read / buffer / document inspect / look, then speak.
        var lookUnderway = false
        var lookServed = false
        var readServed = false
        // ASKED ONCE for the turn — the same question decides the pre-look here
        // and the inspired-sight line below.
        let asksLook = LookClassifier.lookQuery(in: userText) != nil
        if readPassages.isEmpty, editIntent == nil, !actionTurn, let dispatcher,
           routeIntent == .perceive || asksLook {
            let sight = await withNanosecondBudget(Self.preLookBudgetNanoseconds) {
                await dispatcher.fetchDeclaredEditorSight(query: userText)
            }
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
                continuation.finish()
                return
            }
            if let sight {
                readPassages = [sight.passage]
                lookServed = true
                readServed = sight.isRead
                readLedger.record(ReadDelivery(
                    route: .prefetched, detail: "declared-editor-sight",
                    characters: sight.passage.count))
                if let glanced = focusTracker.latestGlancePlace(),
                   let application = glanced.application,
                   let routable = Self.routableApplicationID(
                       application,
                       profiles: dispatcher.applicationProfiles,
                       focusTracker: focusTracker) {
                    recentApplicationReferent = (routable, Date())
                }
            } else if dispatcher.wouldServeLook() {
                lookUnderway = true
            }
        }
        let lookWould = dispatcher?.wouldServeLook() ?? false
        let lookLine = "look — wouldServe=\(lookWould) served=\(lookServed) read=\(readServed) underway=\(lookUnderway)"
        Self.turnLog.info("\(lookLine, privacy: .public)")

        // Snapshot Seer's messages BEFORE the orchestrator starts mutating history with Skill turns.
        // Stale-grounding windows (accepted): - W1 — routine settles mid-Lane-A: this snapshot predates a doneMarker/follow-up…
        let messages = spokenMessages()
        // The route is in hand; there is nothing to fetch back out of the store.
        let inspiredSight = route.inspiresSight
            && (routeIntent == .perceive || asksLook)
        let instructions = seerInstructionsProvider(SeerPass(
            readPassages: readPassages,
            // THE ROUTER'S OWN VERDICT, carried rather than re-derived.
            conversational: routeIntent == .converse,
            runningActionLabels: activeRoutines.values.map(\.label),
            lookUnderway: lookUnderway,
            inspiredSight: inspiredSight,
            perceiving: routeIntent == .perceive,
            exchangeID: originUserTurnID))
        let laneSeed = history

        // Lane B is an UNSTRUCTURED task: it can outlive the turn as a detached routine.
        let emitter = LaneEmitter(continuation: continuation)
        let laneTask: Task<OrchestratorLaneResult, Never>?
        // Completion signal for the grace race — awaiting Task.value directly
        // in a task group pins the group to the lane's duration (value is not
        // cancellation-responsive); a finished AsyncStream is.
        let laneSignal: AsyncStream<Void>?
        let laneSpawn = DispatchTime.now()
        // Attached until the grace race detaches. Flipped once; the lane reads it each round.
        let laneAttachment = LaneAttachment()
        do {
            let seed = laneSeed
            let prompt = systemPrompt
            let target = located
            let (signal, signalContinuation) = AsyncStream<Void>.makeStream()
            laneSignal = signal
            laneTask = Task { [weak self] in
                let result = await self?.runOrchestratorLane(
                    userText: userText, systemPrompt: prompt,
                    seed: seed, emitter: emitter, target: target,
                    worldVetoArming: worldVetoArming,
                    traceID: traceID,
                    actionTurn: actionTurn, editIntent: editIntent,
                    routeIntent: routeIntent,
                    writingTarget: writingTarget,
                    lookUnderway: lookUnderway,
                    servedByPreLook: lookServed,
                    servedByRead: readServed,
                    attachment: laneAttachment) ?? OrchestratorLaneResult()
                signalContinuation.finish()
                return result
            }
        }
        // Lane A: realtime WebSocket route when enabled and ready; classic
        // SSE otherwise. A realtime failure before any event fell through
        // invisibly — rerun classic (rule 2).
        var seerLane: SeerLaneResult
        var serverVoiced = false
        if actionTurn {
            // Action-first rhythm: no Lane A at all — no Seer stream, no "I'm on it", no TTS. The command dispatches at full speed and the Skill chips are the reply.
            Self.turnLog.info("laneA — skipped; actionTurn so chips would be the reply")
            seerLane = SeerLaneResult()
        } else if let realtime = seerRealtime, await realtime.isReady() {
            Self.turnLog.info("laneA — speaking")
            let outcome = await runRealtimeSeerLane(
                realtime: realtime, messages: messages,
                instructions: instructions,
                exchangeID: originUserTurnID, continuation: continuation)
            if outcome.fellBackPreStream, !Task.isCancelled {
                seerLane = await runSeerLane(
                    seerChat: seerChat, messages: messages,
                    instructions: instructions,
                    exchangeID: originUserTurnID, continuation: continuation)
            } else {
                seerLane = outcome.result
                serverVoiced = outcome.serverVoiced
            }
        } else {
            Self.turnLog.info("laneA — speaking")
            seerLane = await runSeerLane(
                seerChat: seerChat, messages: messages,
                instructions: instructions,
                exchangeID: originUserTurnID, continuation: continuation)
        }

        var spokenText = seerLane.text

        if Task.isCancelled {
            // Barge-in: keep what happened so the conversation stays coherent — the lane's Skill pairs and the partial reply.
            laneTask?.cancel()
            if let laneTask,
               // BOUNDED, even here. `Task.value` ignores cancellation
               let lane = await bounded(attachedLaneBudget, { await laneTask.value }) {
                appendHistory(contentsOf: lane.laneTurns, epoch: epoch)
            }
            if !spokenText.isEmpty {
                appendHistory(
                    BrainTurn(role: .assistant, text: sanitizedSpoken(spokenText)),
                    epoch: epoch)
                noteOfferedProse(spoken: spokenText, place: leadPlace)
            }
            continuation.finish()
            return
        }

        // Join or detach. Seer-offline-with-no-text must await fully — the orchestrator's prose is the only voice left.
        var orchestratorLane: OrchestratorLaneResult?
        var laneStalled = false
        if let laneTask, let laneSignal {
            if seerLane.failed, spokenText.isEmpty {
                orchestratorLane = await bounded(attachedLaneBudget) { await laneTask.value }
                laneStalled = orchestratorLane == nil
            } else if await laneFinished(
                signal: laneSignal,
                grace: actionTurn ? actionJoinGraceNanoseconds : laneJoinGraceLiveNanoseconds) {
                // The signal already SAID the lane finished, so this await returns immediately in every healthy case
                orchestratorLane = await bounded(attachedLaneBudget) { await laneTask.value }
                laneStalled = orchestratorLane == nil
            }
        }
        if laneStalled {
            laneTask?.cancel()
            Self.laneLog.error("attached lane exceeded its cap — speaking the honest stall line")
            readLedger.record(ReadDelivery(
                route: .expiredUnanswered,
                detail: Self.routineLabel(from: userText), characters: 0))
        }

        let laneElapsedMs = (DispatchTime.now().uptimeNanoseconds - laneSpawn.uptimeNanoseconds) / 1_000_000
        if let lane = orchestratorLane {
            Self.laneLog.info("lane joined in \(laneElapsedMs)ms")
            let names = lane.outcomes.map(\.skillName)
            if names.isEmpty {
                Self.turnLog.info("laneB — joined with no skill outcomes")
            } else {
                let line = "laneB — ran \(names.joined(separator: ", "))"
                Self.turnLog.info("\(line, privacy: .public)")
            }
            appendHistory(contentsOf: lane.laneTurns, epoch: epoch)
        } else if let laneTask, !laneStalled {
            // …and a STALLED lane never gets here: it already blew the cap a
            // routine would have given it and was cancelled, so registering it
            // as a routine would only buy it a second seven minutes to fail in.
            Self.laneLog.info("lane detached after grace (\(laneElapsedMs)ms since spawn; exclusiveEngine=\(self.engine.requiresExclusiveGeneration))")
            // NOBODY IS WAITING ON IT FROM HERE. Flipped before the routine is registered, so the lane's very next round already knows it is background work
            laneAttachment.detach()
            makeRoomForDetachedRoutine()
            // DETACH: the turn completes now; the lane becomes a routine and reports through the proactive channel when it finishes.
            let routineID = UUID()
            var routine = ActiveRoutine(
                id: routineID, task: laneTask, userText: userText,
                label: Self.routineLabel(from: userText),
                originUserTurnID: originUserTurnID,
                isActionTurn: actionTurn,
                // Read HERE, on the actor, inside the turn — the utterance
                // override is still installed and `effectiveFocus()` is still
                // the world the user asked in.
                originFocus: focusTracker.effectiveFocus(),
                // Born from a superseded turn (cancelled mid-grace, the lane detaches AFTER the new turn's supersede sweep ran): the user already moved on
                supersededByNewTurn: !turnBox.isCurrent(epoch),
                // The pre-read's passage went out with this turn's voice; a
                // lane that only re-reads it has nothing left to say.
                servedByPreRead: !readPassages.isEmpty,
                // Read HERE, on the actor, for the same reason `originFocus`
                // is: these are facts about the turn that spawned the routine,
                // and the routine settles long after that turn is over.
                editIntent: editIntent,
                writingTarget: writingTarget,
                locatedTarget: located,
                // FROM THE SPAWN, NOT FROM HERE. Detach is ~250 ms later on a spoken turn and up to five seconds later on an action turn
                spawnedAt: laneSpawn,
                watchdogTask: nil,
                progressTask: nil)
            // The watchdog: a lane that never returns must still settle the
            // routine so the UI's "still working" state can't stick.
            let cap = routineWatchdogNanoseconds
            routine.watchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: cap)
                guard !Task.isCancelled else { return }
                // The watchdog is born inside the originating turn's task, so an unstructured Task would inherit its raw selection handoff.
                await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                    await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                        await self?.expireRoutine(id: routineID)
                    }
                }
            }
            // Second clock — the one the user can hear.
            let marks = routineProgressMarks
            let spawn = routine.spawnedAt
            routine.progressTask = Task { [weak self] in
                for mark in marks {
                    let elapsed = DispatchTime.now().uptimeNanoseconds
                        &- spawn.uptimeNanoseconds
                    if mark > elapsed {
                        try? await Task.sleep(nanoseconds: mark - elapsed)
                    }
                    guard !Task.isCancelled else { return }
                    // Progress is proactive work too. It currently does not render ambient facts
                    await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                        await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                            await self?.speakRoutineProgress(id: routineID)
                        }
                    }
                }
            }
            activeRoutines[routineID] = routine
            // Detach identity rides the TURN stream (before .completed), so
            // the app learns "this bubble is a routine's home" strictly
            // before the turn finalizes — the empty-bubble-drop race closes.
            continuation.yield(.routineDetached(originUserTurnID: originUserTurnID))
            emitter.flipToDetached(proactive, originUserTurnID: originUserTurnID)
            proactive.yield(.routineStarted(
                routineID: routineID,
                label: routine.label,
                originUserTurnID: originUserTurnID))
            // Registered in `settleTasks` (self-removing) so quiescence can
            // enumerate the settle hop — the one piece of routine work that
            // used to be untracked.
            settleTasks[routineID] = Task { [weak self] in
                let result = await laneTask.value
                // Lane B keeps the initiating turn's snapshot while it is executing the requested action.
                await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                    await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                        await self?.finishRoutine(result, id: routineID)
                    }
                }
                await self?.removeSettleTask(id: routineID)
            }
        }

        // A turn cancelled during the join grace was superseded or barged in AFTER its voice finished (an in-stream cancel exits through the barge-in branch above): any…
        if Task.isCancelled {
            appendCancelledEpilogue(
                spokenText: spokenText, actionTurn: actionTurn,
                outcomes: orchestratorLane?.outcomes ?? [], epoch: epoch)
            continuation.finish()
            return
        }

        // A classified COMMAND the orchestrator judged "pure conversation" is a contradiction — re-roll ONCE with the retry note, then speak an honest failure.
        if actionTurn, let lane = orchestratorLane,
           lane.outcomes.isEmpty, lane.confirmQuestion == nil, !Task.isCancelled {
            let seed = laneSeed
            let retryPrompt = systemPrompt + "\n\n" + MaryPrompts.actionRetryNudge
            let retryTarget = located
            guard let retry = await bounded(
                attachedLaneBudget,
                { [weak self] () async -> OrchestratorLaneResult in
                return await self?.runOrchestratorLane(
                    userText: userText,
                    systemPrompt: retryPrompt,
                    // Retry carries the passage too.
                    seed: seed, emitter: emitter, target: retryTarget,
                    worldVetoArming: worldVetoArming,
                    routeIntent: routeIntent, writingTarget: writingTarget)
                    ?? OrchestratorLaneResult()
            }) else {
                // Degrade to the same honest sentence a watchdog expiry
                // speaks: the retry never came back, so nothing may claim it
                // did.
                Self.laneLog.error("action retry exceeded its cap — speaking the honest stall line")
                readLedger.record(ReadDelivery(
                    route: .expiredUnanswered,
                    detail: Self.routineLabel(from: userText), characters: 0))
                let line = Self.stalledLine(label: Self.routineLabel(from: userText))
                continuation.yield(.token(line))
                appendHistory(
                    BrainTurn(role: .assistant, text: sanitizedSpoken(line)), epoch: epoch)
                continuation.yield(.completed(fullText: line))
                continuation.finish()
                return
            }
            appendHistory(contentsOf: retry.laneTurns, epoch: epoch)
            // The downstream ladder — failure speak, confirm relay, history
            // marker — sees the retry's result, not the empty first roll.
            orchestratorLane = retry
            // The retry await is a suspension: a preempt or supersede can land during it.
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: spokenText, actionTurn: actionTurn,
                    outcomes: retry.outcomes, epoch: epoch)
                continuation.finish()
                return
            }
            if retry.outcomes.isEmpty, retry.confirmQuestion == nil {
                // AN IGNORED INSTRUCTION GETS REPLACED BY A MECHANISM.
                let offer = retry.affordanceOffer
                    ?? orchestratorLane?.affordanceOffer
                let acted = offer.map { $0.score >= AffordanceProbe.confidentFloor } == true
                    ? await dispatchAffordanceAct(
                        goal: userText, continuation: continuation, epoch: epoch)
                    : nil
                if let acted {
                    // Silent on success, spoken on failure — the action-turn rhythm, unchanged.
                    if !acted.ok {
                        continuation.yield(.token(acted.summary))
                        spokenText = acted.summary
                    }
                } else {
                    let line = writingTarget == .selection
                        ? Self.couldNotReplaceSelectionLine()
                        : Self.couldNotActLine(label: Self.routineLabel(from: userText))
                    continuation.yield(.token(line))
                    spokenText = line
                }
            }
        }

        // Rule 4: everything after a server-voiced lane — CONFIRM questions,
        // fallback prose — is narrated by the local voice.
        if serverVoiced {
            continuation.yield(.speechSource(.local))
        }

        // Attached lane blew its cap. Speak first.
        if laneStalled {
            let line = Self.stalledLine(label: Self.routineLabel(from: userText))
            let sentence = spokenText.isEmpty ? line : " \(line)"
            continuation.yield(.token(sentence))
            spokenText += sentence
        }

        if seerLane.failed, spokenText.isEmpty {
            if actionTurn, !(orchestratorLane?.outcomes.isEmpty ?? true) {
                // The action lane has grounded outcomes and the action-first
                // contract is silent success. A missing voice lane must not
                // add an ungrounded blanket claim after the fact.
            } else {
                // Seer never spoke — the orchestrator's captured prose is the
                // best available reply. With no grounded outcome, say only
                // what is known; never imply an action ran.
                let fallback = (orchestratorLane?.text.isEmpty ?? true)
                    ? "I can't reach Seer right now, so I'm without my usual voice."
                    : orchestratorLane!.text
                continuation.yield(.token(fallback))
                spokenText = fallback
            }
        } else if seerLane.failed {
            let notice = " …I lost the rest of that thought — the Seer connection dropped."
            continuation.yield(.token(notice))
            spokenText += notice
        } else if spokenText.isEmpty, !actionTurn,
                  let laneText = orchestratorLane?.text, !laneText.isEmpty {
            // Seer succeeded but said nothing (rare) — don't leave silence.
            // Action turns are silent BY DESIGN: never speak orchestrator
            // prose for them.
            continuation.yield(.token(laneText))
            spokenText = laneText
        }

        // Takeover: Lane A's acknowledgement is replaced, not appended.
        var voicedText = spokenText
        if !laneStalled, !seerLane.failed, !spokenText.isEmpty,
           let lane = orchestratorLane,
           lane.confirmQuestion == nil,
           !lane.outcomes.isEmpty,
           Self.unrecoveredFailure(in: lane.outcomes) == nil,
           !lane.outcomes.contains(where: \.deferred),
           lane.outcomes.contains(where: { dispatcher?.isReadOnly($0.skillName) == false }),
           !KokoroStreamSpeaker.mayAlreadyBeAudible(spokenText) {
            continuation.yield(.retractSpeech)
            voicedText = ""
        }

        // Trace: voice spoke on a non-action turn with no mutating lane outcome.
        if !actionTurn, !spokenText.isEmpty,
           orchestratorLane?.outcomes.contains(where: {
               dispatcher?.isReadOnly($0.skillName) == false
           }) != true {
            AmbientTraceLog.shared.noteVoiceSpokeWithoutMutation()
        }

        // Silent success, SPOKEN failure — on EVERY path.
        if let lane = orchestratorLane,
           let firstFailure = Self.unrecoveredFailure(in: lane.outcomes) {
            let standalone = "That didn't go through — \(firstFailure.summary)"
            let line = voicedText.isEmpty
                ? standalone
                : " Though — that didn't go through: \(firstFailure.summary)"
            continuation.yield(.token(line))
            spokenText = actionTurn ? standalone : Self.filed(spokenText, line)
            voicedText += line
        }

        // Reads the lane performed and joined — and where they go now.
        var laneReads: [LaneOutcome] = []
        if !actionTurn, let lane = orchestratorLane, lane.confirmQuestion == nil {
            laneReads = lane.outcomes.filter {
                $0.ok && !$0.deferred && dispatcher?.isReadOnly($0.skillName) == true
                    && !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        // A MISS IS NOT A DELIVERY. `foundNothing` says the binding looked and the thing is not there
        // PIN: The ALTERNATION marker below deliberately keeps counting misses: that read genuinely RAN
        let joinedReads = laneReads.filter { !$0.foundNothing }
        if !joinedReads.isEmpty, readPassages.isEmpty {
            // DID *THESE* READS LAND? Matched by CONTENT, in the same spirit as `noteSpoken`
            let held = world.store.reads(since: turnStartedAt)
            let landed = held.contains { fact in
                !fact.content.isEmpty
                    && joinedReads.contains { $0.summary.contains(fact.content) }
            }
            readLedger.record(ReadDelivery(
                route: landed ? .registered : .discarded,
                detail: joinedReads.map(\.skillName).joined(separator: ", "),
                characters: joinedReads.reduce(0) { $0 + $1.summary.count }))
        }

        // G4 — A REVISION REPORTS ITSELF, on the JOINED path.
        if let sentence = revisionReport(
            intent: editIntent, target: located,
            writingTarget: writingTarget,
            acceptedOffer: acceptedOffer,
            outcomes: orchestratorLane?.outcomes ?? [],
            after: voicedText, continuation: continuation) {
            spokenText = Self.filed(spokenText, sentence)
            voicedText += sentence
        }

        // A protected action came out of this turn's orchestration: relay its question deterministically (never trusting model prose to ask).
        if let question = orchestratorLane?.confirmQuestion,
           dispatcher?.hasPendingSkillConfirmation == true {
            let sentence = voicedText.isEmpty ? question : " \(question)"
            continuation.yield(.token(sentence))
            spokenText = Self.filed(spokenText, sentence)
            voicedText += sentence
        }

        // History write. A silent action turn still needs a NON-EMPTY assistant turn: spokenMessages() drops empty ones from the Seer wire
        let historyText: String
        if !spokenText.isEmpty {
            historyText = spokenText
        } else if actionTurn {
            if let lane = orchestratorLane {
                let skills = lane.outcomes.map(\.skillName)
                if skills.isEmpty {
                    historyText = "(no action was needed)"
                } else if lane.outcomes.contains(where: \.deferred) {
                    // A deferred spawn joined in-turn: the marker must carry the ack ("(started: delegate_coding
                    historyText = Self.doneMarker(outcomes: lane.outcomes)
                } else {
                    historyText = "(ran: \(skills.joined(separator: ", ")))"
                }
            } else {
                historyText = "(on it)"
            }
        } else if !laneReads.isEmpty {
            // ALTERNATION on a read turn — the reason `laneReads` outlived the second pass.
            historyText = "(read: \(laneReads.map(\.skillName).joined(separator: ", ")))"
        } else {
            historyText = spokenText
        }
        // Stripped before persisting: history is replayed to Seer every
        // later turn — a leaked blob here becomes a parrot loop.
        appendHistory(
            BrainTurn(role: .assistant, text: sanitizedSpoken(historyText)),
            epoch: epoch)
        // Offered prose from spokenText, never historyText (that may be a read marker).
        noteOfferedProse(spoken: spokenText, place: leadPlace)

        // Write back what was spoken about a fact.
        if !readPassages.isEmpty, !spokenText.isEmpty {
            // Return value is consumed here (it used to be discarded).
            let spokenKeys = world.store.noteSpoken(contentsIn: readPassages, note: spokenText)
            for key in spokenKeys {
                guard case .namedRead(let document, _) = key.slot,
                      let document, !document.isEmpty else { continue }
                // Fact key already carries the lane — spoken-about lands on the app, not the host.
                wiring.containers.noteEvidence(
                    place: key.place, key: document, .spokenAbout)
            }
        }

        if let contribution = seerLane.contribution, let json = contribution.jsonString {
            continuation.yield(.contribution(json: json))
        }
        continuation.yield(.completed(fullText: spokenText))

        // Seer folded the conversation into a memory — retain only the final
        // exchange, mirroring Sis's ChatStream truncation, and tell the app
        // so the visible transcript collapses the same way.
        if seerLane.autoMemory {
            truncateAfterAutomemory()
            continuation.yield(.autoMemoryTriggered)
        }
        continuation.finish()
    }

    /// Waits up to the grace window for the lane's completion signal — fast skills stay in-turn, slow ones detach.
    private func laneFinished(signal: AsyncStream<Void>, grace: UInt64) async -> Bool {
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in signal {}   // ends when the lane finishes
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: grace)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished && !Task.isCancelled
        }
    }

    /// HOW LONG AN ATTACHED LANE MAY HOLD THE TURN — the routine watchdog, expressed in seconds for `bounded`.
    /// PIN: Not a new number, and deliberately not one: the same lane, one grace window earlier
    private var attachedLaneBudget: TimeInterval {
        Double(routineWatchdogNanoseconds) / 1_000_000_000
    }
}

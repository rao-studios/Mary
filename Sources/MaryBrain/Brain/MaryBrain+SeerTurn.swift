//
//  MaryBrain+SeerTurn.swift
//  MaryBrain
//
//  Seer mode's coordinator, moved out of MaryBrain.swift: the lane result
//  types (`SeerLaneResult`, `LaneOutcome`, `OrchestratorLaneResult`), the
//  whole `seerTurn` dual-lane function (verbatim, unsplit), `laneFinished`,
//  and `attachedLaneBudget`.
//
//  Moved verbatim; no behavior change. Depends on the internal-for-split
//  promotions of the core file's stored lane state (seerChat, seerRealtime,
//  routineWatchdogNanoseconds, activeRoutines…); treat all of them as
//  private.
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

    /// One dispatched Skill's settled outcome inside a lane — a named type
    /// (not a tuple) so `deferred` rides along: a fire-and-forget ack whose
    /// real result lands later on another channel must never be narrated as
    /// a FINISHED result.
    struct LaneOutcome: Sendable {
        var skillName: String
        var summary: String
        var ok: Bool
        var deferred: Bool = false
        /// `SkillOutcome.foundNothing`, carried the last hop — the binding
        /// LOOKED and what was asked for is not in what it can read.
        ///
        /// THE FAILURE THIS FIXES (traced from the shipped miss): the lane built
        /// its outcomes from `SkillOutcome` and dropped this field on the
        /// floor, so "a miss may never be dressed as a passage" held only where
        /// `AbilityRuntime.readNamedPart` enforces it — the fetch-first road.
        /// A `pages_body` miss arriving by the DETACHED road was ok:true,
        /// non-deferred and read-only, which is every gate the follow-up checks:
        /// it selected the READ persona, went into `readPassageBlock`, and
        /// `readBackNudge` told the voice to give them the words. Mary recited
        /// "…Headers, footers, text boxes and table cells live outside body
        /// text…" aloud as though it were the passage — and now that a miss
        /// carries the whole document back with it, that recitation is the whole
        /// document too. The ledger booked it `.spokenDetached` with the miss's
        /// own character count: a delivery failure wearing a success's clothes.
        ///
        /// A flag that stops one hop short of the mouth it exists to shut is not
        /// an invariant, it is a coincidence about which road you took.
        var foundNothing: Bool = false
        /// `SkillOutcome.status == .requested` — a CONFIRM park. The park is
        /// `ok: true` (nothing failed) and NOT `deferred` (nothing started, so
        /// "the real result lands later" would be a lie `doneMarker` turns
        /// into "(started: …)"). It is its own state: parked, awaiting the
        /// user. Anything that narrates finished work must filter it, or the
        /// voice claims completion for an action that never ran — the live
        /// "The text is now in Times New Roman" failure, verbatim.
        var requested: Bool = false
        /// `SkillOutcome.editDisposition`, carried the last hop — same rule as
        /// `foundNothing` above: this is the one place the flag can be lost,
        /// and `EditReport` refusing to speak "Done" over an unconfirmed
        /// write only holds if the mapping sites carry it.
        var editDisposition: EditDisposition? = nil
        /// `SkillOutcome.ambientDeposited` — the read's content already lives
        /// in ambient context ("Still in hand"), so reciting its machine
        /// summary aloud is redundant. The silent-settle gate reads this.
        var ambientDeposited: Bool = false
        /// `SkillOutcome.status == .blocked` — a POLICY refusal (the mismatch
        /// mirror, a schema-policy denial), distinct from an adapter failure.
        /// Carried the last hop for `foundNothing`'s reason: the settle policy
        /// must tell "the rules said no" apart from "the attempt broke".
        var blocked: Bool = false
        /// `SkillOutcome.landed` — the acting intent is satisfied. Carried the
        /// last hop for the same reason `foundNothing` and `editDisposition`
        /// are, and this struct has now lost a flag here twice: the
        /// continuation nudge reads it, and a nudge that cannot see it will
        /// tell the model to redo work that is already done.
        var landed: Bool = false
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
        /// The control the screen was offering when this lane ran nothing —
        /// set by the affordance escape, and the evidence the turn-level last
        /// rung needs. Carried on the result rather than re-probed there:
        /// re-asking would be a second reading of a screen that may have
        /// changed between the two, and the sentence a user hears must be
        /// about the control that was actually seen.
        var affordanceOffer: AffordanceCandidate?
    }

    // internal for file split — treat as private
    func seerTurn(
        userText: String,
        originUserTurnID: UUID,
        systemPrompt: String,
        actionTurn: Bool = false,
        editIntent: EditIntent? = nil,
        target located: LocatedPassage? = nil,
        writingTarget: AmbientWritingTarget? = nil,
        /// True when this turn is a synthesized accepted-offer revision —
        /// EditReport's silent-miss arm keys on it.
        acceptedOffer: Bool = false,
        /// The world-boundary backstop, armed by the turn loop from the same
        /// admission formula the roster scope uses.
        worldVetoArming: WorldVeto.Arming? = nil,
        /// Stage-0 observation only: which `AmbientTraceLog` row this turn's
        /// Skill calls belong to. Threaded rather than correlated by time
        /// because a detached routine dispatches after the next turn has
        /// started, and a shadow measurement that silently files those under
        /// the wrong utterance is worse than no measurement.
        traceID: UUID? = nil,
        routeIntent: AmbientIntent? = nil,
        /// WHERE this turn is happening, for the prose offer this reply may
        /// carry: an offer made about a manuscript must be written back into
        /// that manuscript, not into whatever is frontmost when the user
        /// accepts it. A place rather than a world so a TAUGHT application can
        /// be named. See `OfferedProse`.
        leadPlace: AmbientPlace? = nil,
        seerChat: any SeerChatProviding,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation,
        epoch: UInt64
    ) async {
        // FETCH FIRST, THEN SPEAK.
        //
        // THE FAILURE THIS FIXES (confirmed against a live bug): a targeted
        // read SUCCEEDED — `pages_body` answered "characters 12927–13835 of
        // 15775, from \"batteries\"" — and the voice denied the passage
        // existed. It could not have done otherwise: `spokenMessages()` drops
        // `.skillName` turns ("Skill plumbing stays local") AND drops the empty
        // carrier assistant turn, so a read is invisible to Seer this turn and
        // every future turn; Lane A's signature is (messages, instructions,
        // continuation) with no dispatcher and no outcome channel; and its
        // messages are snapshotted BELOW, before Lane B is even spawned.
        //
        // So when the request names a part of the document, the read happens
        // HERE — before either lane exists — and the passage rides `liveWork`,
        // the one channel that already reaches the voice end to end. One
        // grounded answer, no retraction.
        //
        // Action turns are excluded: they have no Lane A to feed, so a
        // pre-read would be pure latency.
        //
        // …AND THAT EXCLUSION IS EXACTLY BACKWARDS FOR A REVISION, which is
        // what the arm above this one is for.
        //
        // The reasoning "an action turn has no Lane A, so reading for it is
        // pure latency" is sound for a COMPOSITION: nothing needs the text.
        // Turn it on "replace the Purpose section with the tighter version" and
        // it inverts — the lane EXECUTING SKILLS is the lane that needs the
        // passage, and it is the one lane fetch-first never fed. So the
        // crisper the imperative, the more certainly the Skill lane ran blind,
        // and the crispest imperative in the session typed the new prose at the
        // caret and left the Purpose section standing.
        //
        // A revision takes the LOCATE path and never the read path. One target,
        // one resolver, no drift: two roads to "which part do they mean?" would
        // be two answers, and the gates below have to be able to name the same
        // passage the edit verb will act on. That locate happens one level up,
        // in `runTurn`, so the LOCAL loop is fed by the same call — see
        // `locateTarget`, and `runTurn`'s note on why it sits above the Seer
        // guard rather than below it.
        //
        // The read ALSO registers an ambient fact on its way through the
        // dispatcher, which is what makes it survive into the next turn — this
        // local is only how it reaches THIS turn's voice.
        let turnStartedAt = Date()
        var readPassages: [String] = []
        if editIntent == nil, !actionTurn, let dispatcher,
           let phrase = NamedPartClassifier.namedPart(in: userText) {
            // A SUSPENSION POINT before any lane exists. Two guards, both
            // required: the budget stops a wedged Pages (ScriptRunner allows
            // 30s) from holding the voice hostage, and the cancellation check
            // below honours the same contract the retry block documents — a
            // superseded turn writes nothing, a still-current cancelled turn
            // must still close its exchange or the next request puts two user
            // roles in a row and breaks alternation.
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

        // THE PRE-LANE LOOK — fetch-first for SIGHT. A look question used to
        // be structurally unanswerable in-turn: the voice's snapshot predates
        // Lane B, look questions never earn the action grace (question
        // openers veto), and a 1-5s vision round trip always outlived the
        // 250ms join — so the voice improvised "I can't see that" while the
        // hands looked, and the truth arrived later or (after the deposited-
        // settle change) not at all. Now the look runs HERE, under its own
        // vision-sized budget, and the description rides `readPassages` into
        // the same authority block the pre-read uses. Two triggers feed one
        // arm: `.perceive` (routing's deixis — "what is this") and the
        // conservative LookClassifier (the "that"-shapes routing deliberately
        // keeps `.converse`). The dispatcher declines cheaply when a world
        // with its own eyes leads.
        var lookUnderway = false
        var lookServed = false
        if readPassages.isEmpty, editIntent == nil, !actionTurn, let dispatcher,
           // A LOOK CLASSIFIER USED TO WIDEN THIS RUNG — "what does this look
           // like", "can you see the…". It belonged to the vision lane, which
           // is not in this cut, so the rung narrows to the routed intent.
           // Narrower is the safe direction: a missed pre-look costs a round
           // trip, and a spurious one costs a screenshot nobody asked for.
           routeIntent == .perceive,
           dispatcher.wouldServeLook() {
            let description = await withNanosecondBudget(Self.preLookBudgetNanoseconds) {
                await dispatcher.lookAtScreen(userText)
            }
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: "", actionTurn: actionTurn, outcomes: [], epoch: epoch)
                continuation.finish()
                return
            }
            if let description {
                readPassages = [description]
                lookServed = true
                readLedger.record(ReadDelivery(
                    route: .prefetched, detail: "look_at_screen",
                    characters: description.count))
                // ARM THE REFERENT FROM THE LOOK. Mary just described what
                // the user is looking at — the NEXT turn's "here"/"it" means
                // that place. Without this, "do you see this Google doc" →
                // (perfect look answer) → "add a draft here" inherited
                // NOTHING, the "draft" cue pulled the turn to TextEdit, and
                // the mismatch mirror had no assertion to defend with. The
                // glanced place maps through the same routableApplicationID
                // ladder the route uses ("browser" → the browser profile),
                // so the referent and the web-writer's target resolver agree
                // by construction.
                if let glanced = focusTracker.latestGlancePlace(),
                   let application = glanced.application,
                   let routable = Self.routableApplicationID(
                       application,
                       profiles: dispatcher.applicationProfiles,
                       focusTracker: focusTracker) {
                    recentApplicationReferent = (routable, Date())
                }
            } else {
                // The look fired and nothing came back in budget — the voice
                // must promise the look, never deny sight; Lane B carries it
                // and the spoken follow-up delivers the description.
                lookUnderway = true
            }
        }

        // Snapshot Seer's messages BEFORE the orchestrator starts mutating
        // history with Skill turns.
        //
        // Stale-grounding windows (accepted):
        // - W1 — routine settles mid-Lane-A: this snapshot predates a
        //   doneMarker/follow-up merge landing during this turn's Lane A, so
        //   the voice grounds on the origin's "(on it)" placeholder for one
        //   turn; the next turn sees the merged text. No cheap mechanical
        //   fix (would require re-streaming Lane A); runningActionsNote
        //   already stops the voice re-promising anything still active at
        //   snapshot time.
        // - W2 — a turn's own Lane B is invisible to its own Lane A:
        //   structural dual-lane; the join path lands Skill pairs for the
        //   NEXT turn, the detach path merges at settle.
        // - W3 — deliberate: dropped merges (mergeFollowUpIntoHistory) mean
        //   a trimmed/superseded origin's results never reach model history;
        //   they remain in Totem deposits + AbilityExecutionLog. The correct trade —
        //   the alternative was attributing results to an unrelated
        //   exchange.
        // - W4 — sub-ms settle between snapshot and note-build: the note may
        //   name a routine that settled a moment ago; harmless tense wobble.
        let messages = spokenMessages()
        // In-turn: resolve LIVE. The utterance override is still installed
        // here (it is cleared by runTurn's defer, which has not run yet), so
        // "live" already means "the world this turn named".
        // Read BEFORE the lane spawns and handed to the provider, so the note
        // renders as a section ahead of the live text instead of being
        // appended after it. Nothing between here and the old append site
        // mutates `activeRoutines` — the lane spawn is a detached Task.
        let instructions = seerInstructionsProvider(SeerPass(
            readPassages: readPassages,
            runningActionLabels: activeRoutines.values.map(\.label),
            lookUnderway: lookUnderway,
            exchangeID: originUserTurnID))
        let laneSeed = history

        // Lane B is an UNSTRUCTURED task: it can outlive the turn as a
        // detached routine. While attached, the coordinator cancels it
        // explicitly (structured cancellation no longer applies). EVERY turn
        // gets a lane — earlier routines keep running in parallel (typing a
        // paragraph while a code change dispatches); the running-actions note
        // just stops the voice from re-promising their results. Resource
        // conflicts (two things wanting the stage) are the StageArbiter's
        // job; engine generation rounds serialize on the engineGate.
        let emitter = LaneEmitter(continuation: continuation)
        let laneTask: Task<OrchestratorLaneResult, Never>?
        // Completion signal for the grace race — awaiting Task.value directly
        // in a task group pins the group to the lane's duration (value is not
        // cancellation-responsive); a finished AsyncStream is.
        let laneSignal: AsyncStream<Void>?
        let laneSpawn = DispatchTime.now()
        // ATTACHED UNTIL THE GRACE RACE SAYS OTHERWISE. Flipped exactly once,
        // at the detach below; the lane reads it every round.
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
            // Action-first rhythm: no Lane A at all — no Seer stream, no
            // "I'm on it", no TTS. The command dispatches at full speed and
            // the Skill chips are the reply. Covers realtime and classic
            // identically by never entering either.
            seerLane = SeerLaneResult()
        } else if let realtime = seerRealtime, await realtime.isReady() {
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
            seerLane = await runSeerLane(
                seerChat: seerChat, messages: messages,
                instructions: instructions,
                exchangeID: originUserTurnID, continuation: continuation)
        }

        var spokenText = seerLane.text

        if Task.isCancelled {
            // Barge-in: keep what happened so the conversation stays coherent
            // — the lane's Skill pairs and the partial reply. (A SUPERSEDED
            // turn's epoch is already stale here, so these appends drop and
            // the amended turn starts from a clean exchange.)
            laneTask?.cancel()
            if let laneTask,
               // BOUNDED, even here. `Task.value` ignores cancellation — that
               // hazard is documented three lines above `laneFinished` and it
               // applies to this await as much as to the join below. A lane
               // suspended inside a 30 s AppleScript does not stop because it
               // was asked to, and an unbounded wait here holds the barged-in
               // turn's continuation open, so the user's NEXT utterance has
               // nowhere to land.
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

        // Join or detach. Seer-offline-with-no-text must await fully — the
        // orchestrator's prose is the only voice left. An ACTION turn has no
        // voice racing it, so it affords a longer grace: joining keeps the
        // chips (and any failure line) in-turn instead of detaching every
        // command into a routine 250ms after an instant empty Lane A.
        //
        // AND "AWAIT FULLY" USED TO MEAN "AWAIT FOREVER". `await laneTask.value`
        // on the Seer-failed path is the one join in this file with no wall
        // clock on either side of it: the watchdog arms at DETACH, and a lane
        // taken by this branch never detaches. So the turn that had already
        // lost its voice was also the turn that could hang without limit —
        // `Task.value` ignores cancellation (the reason `laneFinished` exists
        // at all), so not even a barge-in released it. Bounded by the same cap
        // the routine watchdog would have given it, on the plain principle that
        // an ATTACHED lane may never outlive what the SAME lane would have been
        // allowed had it detached; past that the turn degrades to the honest
        // stall line instead of to silence.
        var orchestratorLane: OrchestratorLaneResult?
        var laneStalled = false
        if let laneTask, let laneSignal {
            if seerLane.failed, spokenText.isEmpty {
                orchestratorLane = await bounded(attachedLaneBudget) { await laneTask.value }
                laneStalled = orchestratorLane == nil
            } else if await laneFinished(
                signal: laneSignal,
                grace: actionTurn ? actionJoinGraceNanoseconds : laneJoinGraceLiveNanoseconds) {
                // The signal already SAID the lane finished, so this await
                // returns immediately in every healthy case; the bound is here
                // because "already finished" is a claim about a stream and the
                // wait is a claim about a task, and the two are not the same
                // sentence.
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
            appendHistory(contentsOf: lane.laneTurns, epoch: epoch)
        } else if let laneTask, !laneStalled {
            // …and a STALLED lane never gets here: it already blew the cap a
            // routine would have given it and was cancelled, so registering it
            // as a routine would only buy it a second seven minutes to fail in.
            Self.laneLog.info("lane detached after grace (\(laneElapsedMs)ms since spawn; exclusiveEngine=\(self.engine.requiresExclusiveGeneration))")
            // NOBODY IS WAITING ON IT FROM HERE. Flipped before the routine
            // is registered, so the lane's very next round already knows it
            // is background work — both for the log and for its place in the
            // engine gate's queue.
            laneAttachment.detach()
            // DETACH: the turn completes now; the lane becomes a routine and
            // reports through the proactive channel when it finishes. Its
            // Skill turns never enter shared history — results reach context
            // via the follow-up merge and the Totem deposits. Several
            // routines may coexist; each carries its own watchdog.
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
                // Born from a superseded turn (cancelled mid-grace, the lane
                // detaches AFTER the new turn's supersede sweep ran): the
                // user already moved on — all-ok settles silently; failures
                // still speak (doctrine). Deterministic at birth, no flag
                // race.
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
                // FROM THE SPAWN, NOT FROM HERE. Detach is ~250 ms later on a
                // spoken turn and up to five seconds later on an action turn,
                // and both the progress marks and the ledger's duration are
                // statements about how long the USER has waited.
                spawnedAt: laneSpawn,
                watchdogTask: nil,
                progressTask: nil)
            // The watchdog: a lane that never returns must still settle the
            // routine so the UI's "still working" state can't stick.
            let cap = routineWatchdogNanoseconds
            routine.watchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: cap)
                guard !Task.isCancelled else { return }
                // The watchdog is born inside the originating turn's task,
                // so an unstructured Task would inherit its raw selection
                // handoff.  Expiry reports later through the proactive path;
                // it must not compose a response using that old selection (or
                // fall through to a newer global one).  Keep an explicit empty
                // scope, not `nil`: nil means "no frozen turn" to the ambient
                // store and would expose a subsequent user selection.
                await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                    await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                        await self?.expireRoutine(id: routineID)
                    }
                }
            }
            // …AND THE SECOND CLOCK, THE ONE THE USER CAN HEAR. Armed here,
            // beside the watchdog, because they are the same kind of promise:
            // the watchdog says "this will end", the marks say "it has not
            // ended yet". Each mark is measured from the lane's SPAWN, so a
            // routine that took five seconds to detach still speaks its first
            // line 45 seconds after the user finished asking — not 50.
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
                    // Progress is proactive work too.  It currently does not
                    // render ambient facts, but giving every deferred routine
                    // arm the same empty scope prevents a future progress
                    // composer from silently reintroducing the old handoff.
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
                // Lane B keeps the initiating turn's snapshot while it is
                // executing the requested action.  Its *deferred report* is a
                // distinct transport: only its immutable origin metadata may
                // cross this boundary, never the source turn's selection.
                await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                    await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                        await self?.finishRoutine(result, id: routineID)
                    }
                }
                await self?.removeSettleTask(id: routineID)
            }
        }

        // A turn cancelled during the join grace was superseded or barged in
        // AFTER its voice finished (an in-stream cancel exits through the
        // barge-in branch above): any detached routine is registered and
        // settles on the proactive channel, but the spoken epilogue —
        // fallbacks, failure lines, .completed — belongs to the replacing
        // turn. Yielding .completed here would let a superseded TEXT turn's
        // runner finalize the NEW turn's bubble with stale text. Barge-in
        // keep-partial survives: its epoch is still current so the append
        // lands; a superseded turn's epoch is stale and the same call drops.
        if Task.isCancelled {
            appendCancelledEpilogue(
                spokenText: spokenText, actionTurn: actionTurn,
                outcomes: orchestratorLane?.outcomes ?? [], epoch: epoch)
            continuation.finish()
            return
        }

        // A classified COMMAND the orchestrator judged "pure conversation"
        // is a contradiction — re-roll ONCE with the retry note, then speak
        // an honest failure. Mechanical gate, not prompt-begging: bounded at
        // one retry, and only for JOINED action lanes (a detached NOOP gets
        // its honest line in finishRoutine — the command is stale by then).
        //
        // AND THE RETRY IS A SECOND WHOLE LANE, which is the part that had no
        // clock: ten more Skill rounds, each of which may sit inside a 300 s
        // subprocess, run here INSIDE the turn where no watchdog can reach them
        // (the watchdog arms at detach, and a retried lane never detaches). The
        // same cap as the join above, for the same reason — a lane the user is
        // waiting on may never outlive the lane the user is not.
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
                    // THE RETRY GETS THE PASSAGE TOO. A revision whose first
                    // roll NOOPed is precisely the roll that needed the target
                    // most, and a retry told "this IS a command" with no
                    // passage in front of it is the blind lane again, one round
                    // later. The design target rides for the same reason.
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
            // The retry await is a suspension: a preempt or supersede can
            // land during it. Same contract as the post-join guard — the
            // spoken epilogue belongs to the replacing turn, and a
            // still-current turn must still close its exchange.
            if Task.isCancelled {
                appendCancelledEpilogue(
                    spokenText: spokenText, actionTurn: actionTurn,
                    outcomes: retry.outcomes, epoch: epoch)
                continuation.finish()
                return
            }
            if retry.outcomes.isEmpty, retry.confirmQuestion == nil {
                // AN IGNORED INSTRUCTION GETS REPLACED BY A MECHANISM.
                //
                // `OfferedProse` states the rule and this is the same case
                // one lane over: the screen was offering a control that
                // plainly served the request, the lane was TOLD so by name,
                // and it declined twice anyway. Speaking "I couldn't work out
                // how to do that" about a button Mary can see and press is
                // the sentence this whole area exists to stop.
                //
                // Gated on `confidentFloor` rather than on any hit, because
                // the model's refusal is evidence too: below that height the
                // candidate is a guess, and a guess pressed without agreement
                // is worse than an honest failure.
                let offer = retry.affordanceOffer
                    ?? orchestratorLane?.affordanceOffer
                let acted = offer.map { $0.score >= AffordanceProbe.confidentFloor } == true
                    ? await dispatchAffordanceAct(
                        goal: userText, continuation: continuation, epoch: epoch)
                    : nil
                if let acted {
                    // Silent on success, spoken on failure — the action-turn
                    // rhythm, unchanged. A press that worked needs no
                    // sentence; a refusal from the hands is far more use than
                    // the generic one below, because it says what was on the
                    // page.
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

        // THE ATTACHED LANE BLEW ITS CAP. Spoken FIRST, and deliberately ahead
        // of the Seer ladder below: the ladder's own fallback ends "…but any
        // actions you asked for did run", which is exactly the untrue sentence
        // this whole area exists to stop. With the stall line in `spokenText`
        // that arm can no longer be reached, and a mid-stream Seer drop still
        // appends its own notice after it.
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

        // THE TAKEOVER — Lane A's acknowledgement is REPLACED, not appended to.
        //
        // THE FAILURE THIS FIXES (verbatim, from a live session): "I'm on it,
        // but I need a quick clarification — do you mean the whole document, or
        // the Background section?" — spoken while REPLACE_PASSAGE had already
        // landed correctly. And, on Apple Music: "it correctly opened Apple
        // Music and played a song, and then followed up after completing the
        // task as if it was doing it at the moment. We need to maintain the
        // speed of the actions, but have the dialogue stay in sync."
        //
        // IT IS STRUCTURAL, NOT A PROMPTING MISS. Lane A is spawned with no
        // dispatcher and no outcome channel, and Lane B is spawned BEFORE it
        // starts — so anything Lane A says about work in flight is a PROMISE,
        // and by the time the lane joins holding finished outcomes that promise
        // is stale by construction. The brain already reaches around Lane A's
        // prose three times (the unrecovered-failure line below, whose own
        // comment says it is "appended after Seer's prose so Lane A's
        // optimistic ack can't stand uncorrected"; the revision report; the
        // CONFIRM relay) and every one of them APPENDS, which leaves the stale
        // sentence standing in FRONT of its own correction. This is the replace
        // arm those three were missing.
        //
        // WHAT MAKES IT SAFE is the consumer: `.retractSpeech` becomes
        // `softStop()`, which drops un-synthesized text and lets audio already
        // in flight drain to a sentence boundary. It never cuts a word in half
        // and it never speaks what it retracted — which is why bound 5 below is
        // about whether the text could ALREADY be audible.
        //
        // FIVE BOUNDS, and each one names a turn this may not touch:
        //  1. THERE IS SOMETHING TO RETRACT, and this turn owns it. A stalled
        //     lane and a dropped Seer connection have just spoken honest lines
        //     about themselves; silencing an apology for silence is absurd.
        //  2. THE LANE JOINED IN-TURN. A detached lane has no outcomes here and
        //     reports through the follow-up channel, where the floor rules
        //     already decide what the ear gets.
        //  3. THE LANE REALLY ACTED — at least one outcome the dispatcher does
        //     NOT call read-only, the same predicate that keeps reads out of
        //     Totem. "Read me the Background section" runs a Skill and gets a
        //     GENUINE conversational answer from Lane A; silencing that is the
        //     reported bug in a new costume, so a read-only lane never retracts.
        //  4. IT ALL LANDED, AND IT LANDED FINISHED. An unrecovered failure and
        //     a surfaced CONFIRM each own the sentence below and outrank this;
        //     a DEFERRED spawn is the one case where "I'm on it" is still TRUE,
        //     because the real result arrives later on another channel, and
        //     narrating it as finished is the lie the `deferred` flag exists to
        //     prevent.
        //  5. IT CANNOT ALREADY BE AUDIBLE. `KokoroStreamSpeaker
        //     .mayAlreadyBeAudible` asks the CHUNKER its own question — has this
        //     text handed a batch to synthesis yet — instead of a second copy of
        //     that arithmetic living here. Below the threshold the retraction is
        //     total; at or above it Lane A wrote a real answer the user is
        //     already hearing, and cutting a reply off mid-flow is worse than
        //     the stale sentence this exists to remove.
        //
        // The deterministic ladder below then becomes the WHOLE spoken reply.
        // When it owes nothing, the turn speaks nothing — the user's decision,
        // verbatim: "a completed fast action stays SILENT, the chips are the
        // reply." `SpeechRouter.finish()` reaches that case with `didFeedSpeaker`
        // back to false and takes the road a zero-token action turn always did:
        // no flush, no audio, no phantom `.started`.
        //
        // `spokenText` IS DELIBERATELY UNTOUCHED. The takeover rewinds the EAR;
        // the transcript bubble and the history turn keep what was written, so
        // alternation, the follow-up merge and the `(ran: …)` marker logic all
        // behave exactly as before. `voicedText` is the parallel accumulator
        // the ladder consults for "is there prose in front of me" — the only
        // question retraction changes the answer to.
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

        // STAGE-0 OBSERVATION of the takeover's inverted case: the voice
        // spoke on a non-action turn and the lane landed nothing that
        // mutates — the shape a false "Done." lives in. Counted, never
        // enforced; the numbers decide whether a fifth mechanism is built.
        if !actionTurn, !spokenText.isEmpty,
           orchestratorLane?.outcomes.contains(where: {
               dispatcher?.isReadOnly($0.skillName) == false
           }) != true {
            AmbientTraceLog.shared.noteVoiceSpokeWithoutMutation()
        }

        // Silent success, SPOKEN failure — on EVERY path. An action turn's
        // failure replaces the (empty) reply; a spoken turn's failure is
        // appended after Seer's prose so Lane A's optimistic ack can't stand
        // uncorrected. Only an UNRECOVERED failure speaks: a mid-chain !ok
        // the model retried past (the lane ends on ok) genuinely succeeded.
        // CONFIRM parks are ok:true and cannot enter here; the confirm relay
        // below still runs independently.
        //
        // The judgement itself lives in `unrecoveredFailure` because the
        // DETACHED follow-up asks the same question, and used to answer it
        // differently — see that function's header.
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

        // A READ THE LANE PERFORMED AND JOINED — and where it goes now.
        //
        // The SECOND SEER PASS that used to speak it here is GONE (the user's
        // decision, from the same live session the rest of this slice comes
        // from). It cost a whole extra network round trip AFTER the audio had
        // drained, with the turn held open and the mic deafened across it —
        // the "as if something was holding it" that session reported. Removing
        // it also removes the `readPassages.isEmpty` suppression flag it
        // needed, and its pins go with it.
        //
        // FETCH-FIRST is the covered path: a request that names a part of the
        // document reads BEFORE either lane exists and the passage rides Lane
        // A's own instructions — one grounded answer, no second pass, no
        // repetition.
        //
        // AND THIS IS WHERE THE AMBIENT STORE CLOSES IT. A read the MODEL chose
        // mid-turn and that joined inside the grace used to reach nobody, and
        // `.discarded` was a true statement about that. The dispatcher now
        // REGISTERS every successful read as an `(world, namedRead:)` fact on
        // its way through, so the same read reaches the NEXT turn's prompt with
        // its age — `.registered` is the honest row for that, and `.discarded`
        // survives for the reads that genuinely land nowhere (a world Mary
        // has no eyes for: calendar, files, mail).
        //
        // Recorded only when fetch-first did NOT deliver, so a turn that really
        // did reach the voice in-turn can't be overwritten with a weaker row.
        var laneReads: [LaneOutcome] = []
        if !actionTurn, let lane = orchestratorLane, lane.confirmQuestion == nil {
            laneReads = lane.outcomes.filter {
                $0.ok && !$0.deferred && dispatcher?.isReadOnly($0.skillName) == true
                    && !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        // A MISS IS NOT A DELIVERY. `foundNothing` says the binding looked and
        // the thing is not there, so a row minted from it would claim a passage
        // reached the prompt when what reached it was an explanation of why
        // there is none — and the ledger's whole job is to be the one place in
        // the process that cannot say that.
        //
        // The ALTERNATION marker below deliberately keeps counting misses: that
        // read genuinely RAN, and what breaks the Seer wire is an EMPTY
        // assistant turn, whatever the read found.
        let joinedReads = laneReads.filter { !$0.foundNothing }
        if !joinedReads.isEmpty, readPassages.isEmpty {
            // DID *THESE* READS LAND? Matched by CONTENT, in the same spirit
            // as `noteSpoken` — the brain never has to learn the store's keys,
            // and a fact's content IS its read's summary, trimmed and capped.
            //
            // It used to be "did the store gain ANY read this turn", which was
            // a sound proxy only while three worlds could register at all. Now
            // that every plugin owner keys facts, a read registered by another
            // path in the same window would report THIS lane's read as
            // delivered — a diagnostic row lying about the exact thing it
            // exists to expose.
            let held = ambient.reads(since: turnStartedAt)
            let landed = held.contains { fact in
                !fact.content.isEmpty
                    && joinedReads.contains { $0.summary.contains(fact.content) }
            }
            readLedger.record(ReadDelivery(
                route: landed ? .registered : .discarded,
                detail: joinedReads.map(\.skillName).joined(separator: ", "),
                characters: joinedReads.reduce(0) { $0 + $1.summary.count }))
        }

        // G4 — A REVISION REPORTS ITSELF, on the JOINED path. Deliberately
        // beside the confirm relay: both are deterministic sentences the brain
        // owns and the model never writes, and both are exceptions to the
        // silence of an action turn.
        //
        // AN ACTION TURN IS SILENT BY DESIGN and that is right for "play the
        // jazz playlist" — the chips are the reply and the music is the
        // confirmation. It is WRONG for a change to the user's own words that
        // they did not watch happen, in a part of a document that may be off
        // screen: the chip says `replace_passage` and nothing says WHERE. The
        // report's whole content is the recoverable bounds — the words it
        // started with, the words it ended with, roughly how much — because
        // those are the only bounds a person can act on.
        //
        // Through `revisionReport` rather than inline, because `localTurn`
        // owes the identical sentence and two copies of it would drift.
        //
        // AND IT IS THE FIRST BENEFICIARY OF THE TAKEOVER ABOVE. `after:` takes
        // `voicedText`, so on a retracted turn the report leads instead of
        // trailing an acknowledgement the ear will never hear — which is
        // precisely the reported incident, answered: "I'm on it, but I need a
        // quick clarification…" is replaced by the sentence saying which words
        // changed.
        if let sentence = revisionReport(
            intent: editIntent, target: located,
            writingTarget: writingTarget,
            acceptedOffer: acceptedOffer,
            outcomes: orchestratorLane?.outcomes ?? [],
            after: voicedText, continuation: continuation) {
            spokenText = Self.filed(spokenText, sentence)
            voicedText += sentence
        }

        // A protected action came out of this turn's orchestration: relay its
        // question deterministically (never trusting model prose to ask).
        // Detached lanes relay theirs through the follow-up instead. Kept for
        // action turns too — a protected action is exactly when the voice
        // SHOULD ask.
        if let question = orchestratorLane?.confirmQuestion,
           dispatcher?.hasPendingSkillConfirmation == true {
            let sentence = voicedText.isEmpty ? question : " \(question)"
            continuation.yield(.token(sentence))
            spokenText = Self.filed(spokenText, sentence)
            voicedText += sentence
        }

        // History write. A silent action turn still needs a NON-EMPTY
        // assistant turn: spokenMessages() drops empty ones from the Seer
        // wire, and a dropped turn would put two consecutive user roles on
        // the next request (breaks alternation). The marker is factual,
        // never spoken, and anchors the follow-up merge for detached lanes.
        let historyText: String
        if !spokenText.isEmpty {
            historyText = spokenText
        } else if actionTurn {
            if let lane = orchestratorLane {
                let skills = lane.outcomes.map(\.skillName)
                if skills.isEmpty {
                    historyText = "(no action was needed)"
                } else if lane.outcomes.contains(where: \.deferred) {
                    // A deferred spawn joined in-turn: the marker must carry
                    // the ack ("(started: delegate_coding — Claude's on it…)")
                    // so next turn's "did it finish?" grounds on STARTED, not
                    // a claimed completion.
                    historyText = Self.doneMarker(outcomes: lane.outcomes)
                } else {
                    historyText = "(ran: \(skills.joined(separator: ", ")))"
                }
            } else {
                historyText = "(on it)"
            }
        } else if !laneReads.isEmpty {
            // ALTERNATION on a read turn — the reason `laneReads` outlived
            // the second pass. A lane that only READ can leave a non-action
            // turn silent after real work happened (Seer said nothing and
            // there is no orchestrator prose to fall back on), and
            // spokenMessages() drops empty assistant turns — two consecutive
            // user roles break the Seer wire and Mistral-family templates.
            // Factual and SKILL-NAMED only: the passage itself must not enter
            // history, or it is replayed to Seer forever as the very
            // self-referential filler the undeposited-reads rule exists to
            // prevent.
            historyText = "(read: \(laneReads.map(\.skillName).joined(separator: ", ")))"
        } else {
            historyText = spokenText
        }
        // Stripped before persisting: history is replayed to Seer every
        // later turn — a leaked blob here becomes a parrot loop.
        appendHistory(
            BrainTurn(role: .assistant, text: sanitizedSpoken(historyText)),
            epoch: epoch)
        // DID SHE OFFER PROSE? `spokenText`, not `historyText` — the latter
        // may be a `(read: …)` marker, which is plumbing and never a draft.
        noteOfferedProse(spoken: spokenText, place: leadPlace)

        // THE TURN LOOP'S WRITE-BACK: what was spoken about a fact. The
        // passage that rode into the voice's instructions IS a fact's own text,
        // so matching by content means the brain never has to learn the store's
        // keys. Next turn the fact renders with "already spoken about", which
        // is how she stops reciting the same passage twice unasked while still
        // holding it for follow-up questions.
        if !readPassages.isEmpty, !spokenText.isEmpty {
            // AND THE RETURN VALUE IS CONSUMED NOW, where it used to be thrown
            // away. `noteSpoken` already computed which facts were spoken
            // about; that is the `.spokenAbout` evidence class, free, and it is
            // what makes "add this to the one you just read me" resolvable.
            let spokenKeys = ambient.noteSpoken(contentsIn: readPassages, note: spokenText)
            for key in spokenKeys {
                guard case .namedRead(let document, _) = key.slot,
                      let document, !document.isEmpty else { continue }
                // BY REALM: the fact's key already carries the lane, so a
                // registered application's spoken-about evidence lands under
                // its own identity rather than the shared host lane.
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

    /// Waits up to the grace window for the lane's completion signal — fast
    /// skills stay in-turn, slow ones detach. Races the signal stream (which
    /// ends iteration on cancellation, unlike Task.value) against a sleep.
    /// A turn cancelled DURING the grace never joins: under cancellation
    /// both racers finish at once (the signal iteration ends and the sleep
    /// throws), so the raw race is a coin flip — and a superseded turn that
    /// "joined" would keep processing as if current. Detaching instead is
    /// deterministic and correct: the lane becomes a routine born
    /// superseded, settling on the proactive channel.
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

    /// HOW LONG AN ATTACHED LANE MAY HOLD THE TURN — the routine watchdog,
    /// expressed in seconds for `bounded`.
    ///
    /// Not a new number, and deliberately not one: the same lane, one grace
    /// window earlier, would have detached and been given exactly this. An
    /// attached lane must never outlive what the same lane would have been
    /// allowed had it detached — otherwise the turn the user is sitting through
    /// is the one with the weaker guarantee. It follows
    /// `setRoutineWatchdogForTesting` for the same reason the watchdog does.
    private var attachedLaneBudget: TimeInterval {
        Double(routineWatchdogNanoseconds) / 1_000_000_000
    }
}

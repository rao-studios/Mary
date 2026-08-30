//
//  MaryBrain+Routines.swift
//  MaryBrain
//
//  Detached-routine lifecycle, moved out of MaryBrain.swift: the nested
//  `ActiveRoutine`, `LateRoutine`, and `ChainEntry` types, and the settle
//  paths — `clearActiveRoutine`, `speakRoutineProgress`, `expireRoutine`,
//  `finishRoutine`, `speakRoutineFollowUp`, `enqueueFollowUp`,
//  `emitCodingFollowUp`, `proactiveYield`. The registries themselves
//  (`activeRoutines`, `expiredRoutines`, `followUpChain`) are stored
//  properties and stay in the core file.
//
//  Moved verbatim; no behavior change. The three nested types are
//  internal-for-split (the core file's stored properties name them); treat
//  them as private, along with the promoted stored state this file reads.
//

import MaryAmbient
import MaryFoundation
import MaryVoice
import Foundation
import os

extension MaryBrain {

    /// Detached lanes beyond this cancel the oldest at the next detach.
    public static let maxDetachedRoutines = 2

    /// Which already-running detached routines must stop so one more can join
    /// without exceeding `cap`. Oldest first.
    public static func idsToCancelForDetachedCap(
        existing: [(id: UUID, spawnedUptime: UInt64)],
        cap: Int = maxDetachedRoutines
    ) -> [UUID] {
        guard cap > 0, existing.count >= cap else { return [] }
        let overflow = existing.count - cap + 1
        return existing
            .sorted { $0.spawnedUptime < $1.spawnedUptime }
            .prefix(overflow)
            .map(\.id)
    }

    /// A detached routine: an orchestrator lane that outlived its turn and
    /// keeps executing in the background.
    // internal for file split — treat as private
    struct ActiveRoutine {
        let id: UUID
        let task: Task<OrchestratorLaneResult, Never>
        let userText: String
        /// Spoken name for the busy note and the stop acknowledgement.
        let label: String
        /// Identity of the user turn that spawned the routine — the anchor
        /// that keeps the follow-up merge on the ORIGINATING exchange even
        /// when newer turns landed while the routine ran.
        let originUserTurnID: UUID
        /// The action-first rhythm: an action routine that succeeds settles
        /// SILENTLY (chips were the reply); only failures speak.
        let isActionTurn: Bool
        /// The world the SPAWNING turn was in — snapshot on the actor at
        /// detach, while `runTurn`'s utterance override is still installed.
        /// The follow-up runs long after that `defer` cleared it, so resolving
        /// focus again there asserts the AMBIENT world: a proofread routine
        /// spawned while Xcode was frontmost would announce "you're
        /// pair-coding in Xcode" and hand over Xcode source as the live work.
        /// Same discipline as `archive()`'s `depositSubjectProvider()`
        /// snapshot — read the world where the world is still true.
        let originFocus: WorkspaceFocus?
        /// The user started a NEW topic while this routine ran — their moving
        /// on reads as "it landed, don't narrate it". All-ok outcomes settle
        /// silently; failures still speak regardless.
        var supersededByNewTurn: Bool = false
        /// FETCH-FIRST ALREADY DELIVERED this turn's passage.
        ///
        /// THE FAILURE THIS FIXES (confirmed against a live user session):
        /// `readPassages` was a `seerTurn` local and never reached the routine,
        /// so a DETACHED fetch-first turn paid three times for one answer — the
        /// pre-read, Lane B's own duplicate `pages_body`, and then a follow-up
        /// Seer round trip that re-narrated the passage the voice had already
        /// spoken (the silent-settle gate declines to swallow a non-action,
        /// non-deferred, ok outcome, so `speakRoutineFollowUp` said it all
        /// again, late, over the top of the reply the user had already heard).
        let servedByPreRead: Bool
        /// THE REVISION THIS ROUTINE IS, if it is one — carried for the same
        /// reason `servedByPreRead` is, and closing the same class of hole.
        ///
        /// THE FAILURE THIS FIXES: the silent-settle arm swallows any all-ok
        /// ACTION routine, and a revision is an action routine. So a change to
        /// the user's words that took longer than the join grace — which is
        /// most of them, a Pages AX write is not fast — would settle in perfect
        /// silence, leaving a document altered somewhere the user was not
        /// looking with nothing said about it at all. Both halves are needed at
        /// settle time: the intent says the turn WAS a revision, and the target
        /// carries the edges the report is made of.
        let editIntent: EditIntent?
        let writingTarget: AmbientWritingTarget?
        let locatedTarget: LocatedPassage?
        /// WHEN THE LANE STARTED — the spawn instant, not the detach.
        ///
        /// The two are ~250 ms apart on a spoken turn and up to five seconds
        /// apart on an action turn (`actionJoinGraceNanoseconds`), and the
        /// difference is not bookkeeping: everything measured from here is a
        /// statement about how long THE USER has been waiting. Seeding the
        /// progress marks or the ledger's duration from detach would report a
        /// lane as five seconds younger than it is, and would put the first
        /// spoken mark five seconds late for exactly the turns that detach
        /// slowest.
        let spawnedAt: DispatchTime
        /// Per-routine wall-clock cap (armed at detach, cancelled at settle).
        var watchdogTask: Task<Void, Never>?
        /// THE SPOKEN WALL CLOCK — two marks, then silence, armed beside the
        /// watchdog and cancelled with it. See `routineProgressMarks`.
        var progressTask: Task<Void, Never>?
    }

    // internal for file split — treat as private
    struct LateRoutine {
        let routine: ActiveRoutine
        let expiredAt: Date
    }

    /// Serializes spoken follow-ups: two background actions finishing near
    /// each other must speak one-after-another — interleaved tokens in the
    /// pipeline's single follow-up buffer would garble both.
    ///
    /// The gate and the origin ride WITH the task because a successor that
    /// steps over this entry has to be able to shut it up and then close the
    /// bubble it shut — see `enqueueFollowUp`.
    // internal for file split — treat as private
    struct ChainEntry {
        let task: Task<Void, Never>
        let gate: EmissionGate
        let origin: UUID?
    }

    // MARK: - Detached routine completion (grounded follow-up)

    func makeRoomForDetachedRoutine() {
        let existing = activeRoutines.map {
            (id: $0.key, spawnedUptime: $0.value.spawnedAt.uptimeNanoseconds)
        }
        for id in Self.idsToCancelForDetachedCap(existing: existing) {
            cancelRoutine(id: id)
        }
    }

    /// Releases ONE routine and its two clocks together — every terminal path
    /// (finish, expiry, bare-stop) goes through here so no half can outlive
    /// another. THREE halves now: the watchdog says "this will end", the
    /// progress marks say "it has not ended yet", and a routine that has ended
    /// must be able to say neither.
    @discardableResult
    // internal for file split — treat as private
    func clearActiveRoutine(id: UUID) -> ActiveRoutine? {
        guard let routine = activeRoutines.removeValue(forKey: id) else { return nil }
        routine.watchdogTask?.cancel()
        routine.progressTask?.cancel()
        // Stashed for the clocks-cancelled test seam only.
        lastClearedRoutine = routine
        return routine
    }

    /// STOP ONE ROUTINE — the single cancel path.
    ///
    /// The bare spoken "stop" used to inline this loop body, and it was the
    /// only way to cancel anything: all-or-nothing, by voice, with no way to
    /// name which of five running routines you meant. A Stop control on one
    /// row needs exactly the same three steps, and two copies of "how a
    /// routine is torn down" is how one of them comes to forget the clocks.
    ///
    /// Returns the routine it stopped, or nil if it had already settled —
    /// a stop arriving a moment late is a race a person can lose honestly.
    @discardableResult
    func cancelRoutine(id: UUID, acknowledgement: String = "") -> ActiveRoutine? {
        guard let routine = activeRoutines[id] else { return nil }
        routine.task.cancel()
        clearActiveRoutine(id: id)
        proactive.yield(.routineCancelled(
            routineID: id,
            acknowledgement: acknowledgement,
            originUserTurnID: routine.originUserTurnID))
        return routine
    }

    /// Self-removal hook for the tracked settle hop — called as the settle
    /// task's last act, on the actor.
    // internal for file split — treat as private
    func removeSettleTask(id: UUID) {
        settleTasks.removeValue(forKey: id)
    }

    /// "STILL WORKING ON …" — the lane's own voice, at each mark.
    ///
    /// IT DOES NOT RIDE THE FOLLOW-UP CHAIN, and that is the one apparent
    /// exception to `enqueueFollowUp`'s invariant ("every `.followUpToken` /
    /// `.followUpCompleted` in this file is yielded from inside a body passed
    /// here"). It is not an exception, because this is neither of those events:
    /// the chain exists so that two writers cannot garble the pipeline's SINGLE
    /// follow-up buffer, and `routineProgress` is delivered on an arm that
    /// never touches that buffer at all — spoken into a quiet room or dropped.
    /// There is nothing for it to interleave with.
    ///
    /// IT DOES NOT MERGE INTO HISTORY either, and that one is load-bearing:
    /// history is replayed to Seer on every later turn, so "Still working on
    /// the Purpose section" would leave the NEXT turn grounding on an
    /// in-progress claim that had long since resolved — the model would keep
    /// saying it was still working after the work landed.
    ///
    /// A routine that settled between the mark firing and this running finds
    /// nothing and says nothing: `clearActiveRoutine` removed it.
    // internal for file split — treat as private
    func speakRoutineProgress(id: UUID) {
        guard let routine = activeRoutines[id] else { return }
        proactive.yield(.routineProgress(
            "Still working on \(routine.label) — I'll tell you the moment it lands.",
            originUserTurnID: routine.originUserTurnID))
    }

    /// Watchdog expiry: cancel the hung lane and say so. Races with
    /// finishRoutine are actor-serialized — whichever runs first removes the
    /// routine, and the other's guard returns.
    ///
    /// IT USED TO SETTLE IN SILENCE, and that silence was the bug. The old body
    /// cancelled, cleared and yielded `.routineSettled` — speaking nothing,
    /// merging nothing into history, enqueueing nothing on the follow-up chain.
    /// `ProactiveEvent.routineSettled`'s own doc comment admitted it: "the
    /// watchdog expired a hung one… nothing is spoken." Confirmed against a
    /// live user session: a user asked, waited out the cap, and was told
    /// NOTHING — the chip simply went dark, and no row anywhere recorded that
    /// an answer had been destroyed.
    ///
    /// AN EXPIRED ROUTINE OWES AN HONEST FAILURE, not a disappearance. The line
    /// rides the same follow-up chain every other spoken path uses (so it
    /// cannot interleave), lands in history under its own exchange (so the next
    /// turn knows the command never completed and "(on it)" is not left
    /// standing), and is named in the read ledger.
    /// Speak one of the DETERMINISTIC settle lines — the honest-failure and
    /// stall sentences — on the follow-up channel, and file it in history.
    ///
    /// THE FAILURE THIS FIXES (live, in the transcript): "I couldn't work out
    /// how to do that — …" printed TWICE, byte-identical, one paragraph above
    /// the other. The in-turn ladder speaks it (`MaryBrain+SeerTurn`'s empty
    /// retry arm, `expireRoutine`'s cap) and then the settle arm here spoke it
    /// again about the same non-event, because only `fallbackFollowUpLine`
    /// carried the containment guard.
    ///
    /// These lines are FIXED TEXT, which is exactly the case an exact-text
    /// guard decides soundly — the reason the streamed compose road is
    /// deliberately left unguarded (a paraphrase doesn't text-match, and
    /// `composeWouldOnlyRestate` owns that judgement) does not apply here.
    ///
    /// HISTORY IS GUARDED TOO, not just the ear: `mergeFollowUpIntoHistory`
    /// appends, so a restatement would leave the same sentence twice in the
    /// text replayed to Seer on every later turn.
    ///
    /// The caller still settles the routine terminally — dropping the sentence
    /// must never leave the app's "still working" state stuck.
    // internal for file split — treat as private
    func speakSettleLine(_ line: String, originUserTurnID origin: UUID?) async {
        guard !Self.addsNothing(line, over: originAssistantText(originUserTurnID: origin)) else {
            Self.laneLog.info("settle line dropped — already said in-turn")
            return
        }
        mergeFollowUpIntoHistory(line, originUserTurnID: origin)
        await enqueueFollowUp(origin: origin) { [weak self] gate in
            guard gate.isOpen else { return }
            self?.proactiveYield(.followUpToken(line, originUserTurnID: origin))
            self?.proactiveYield(.followUpCompleted(fullText: line, originUserTurnID: origin))
        }
    }

    // internal for file split — treat as private
    func expireRoutine(id: UUID) async {
        guard let routine = activeRoutines[id] else { return }
        routine.task.cancel()
        clearActiveRoutine(id: id)
        // KEPT, NOT DROPPED. The lane was asked to stop; it may not have, and
        // if it comes back with a real result that result is still an answer.
        // Pruned on the way in — a lane two whole watchdogs past its own
        // cancellation is never returning, and a map that only grows is a leak
        // wearing a safety net's clothes.
        let now = Date()
        let staleAfter = Double(routineWatchdogNanoseconds) / 1_000_000_000 * 2
        expiredRoutines = expiredRoutines.filter {
            now.timeIntervalSince($0.value.expiredAt) < staleAfter
        }
        expiredRoutines[id] = LateRoutine(routine: routine, expiredAt: now)
        let origin = routine.originUserTurnID
        let seconds = Int(routineWatchdogNanoseconds / 1_000_000_000)
        Self.laneLog.error("routine expired after \(seconds)s — speaking the honest failure")
        readLedger.record(ReadDelivery(
            route: .expiredUnanswered,
            detail: "\(routine.label) — lane ran \(Self.spokenDuration(since: routine.spawnedAt))",
            characters: 0))
        await speakSettleLine(Self.stalledLine(label: routine.label), originUserTurnID: origin)
        proactive.yield(.routineSettled(routineID: id, originUserTurnID: origin))
    }

    /// The follow-up chain: each spoken follow-up awaits every earlier one.
    /// Actor-isolated bookkeeping; the body runs on the actor as well.
    ///
    /// THE INVARIANT: every `.followUpToken` / `.followUpCompleted` in this
    /// file is yielded from inside a body passed here. Nothing spoken may
    /// bypass the chain — the pipeline owns ONE text buffer and one diff
    /// baseline, so two unserialized writers garble both (and the in-turn
    /// spoken pass that used to bypass it, `speakInTurnRead`, was deleted for
    /// exactly that reason). If a new spoken path is ever added, it enqueues
    /// here or it is a bug.
    ///
    /// AND THE CHAIN MUST NOT BE POISONABLE. What stood here was three
    /// unbounded awaits — `previous?.value`, `body()`, and the caller's own
    /// `task.value` — over a `followUpChain` that was never cancelled and never
    /// reset. One body that never returned therefore blocked every later
    /// follow-up FOREVER, and blocked `finishRoutine` too, so
    /// `.routineSettled` never fired and the "still working" chip stayed lit
    /// for the rest of the session. Confirmed against a live user session: an
    /// earlier Pages routine's wedged Seer stream ate the calendar answer that
    /// came after it, and nothing but that stream ending could ever release it.
    ///
    /// Three rungs of `bounded` (see the ladder above) turn each of those into
    /// a deadline. Ordering survives every healthy case; only a wedged entry is
    /// stepped over, and it is NAMED in the ledger when it happens rather than
    /// costing another trace.
    ///
    /// AND A STEPPED-OVER ENTRY MUST BE SILENCED, NOT MERELY OVERTAKEN — the
    /// hole the ladder itself opened. `bounded` releases the CALLER and then
    /// asks the loser to stop; a body wedged inside a non-cancellable await
    /// does not stop, and it still holds a live `seerChat` stream. So the
    /// abandoned body kept yielding `.followUpToken` — into the pipeline's
    /// SINGLE follow-up buffer, minutes later, on top of whichever successor
    /// had taken the floor. Two writers, one buffer: exactly the garbling this
    /// chain exists to prevent, reintroduced by the mechanism that was supposed
    /// to protect it. Each entry therefore carries an `EmissionGate`, closed by
    /// whoever gives up on it, and every yield in every body checks it.
    ///
    /// `origin` is here so the give-up path can CLOSE THE BUBBLE it silenced:
    /// suppressing a body's tokens without a terminal would leave the
    /// transcript accumulating for that origin forever and the voice
    /// pipeline's buffer holding a fragment that never plays. An empty
    /// `.followUpCompleted` finalizes whatever partial text arrived.
    // internal for file split — treat as private
    func enqueueFollowUp(
        origin: UUID?,
        _ body: @escaping @Sendable (EmissionGate) async -> Void
    ) async {
        let previous = followUpChain
        let ledger = readLedger
        let chainWait = chainWaitBudget
        let bodyCap = bodyBudget
        let gate = EmissionGate()
        let channel = proactive
        let task = Task {
            // The chain is the last line of defence: callers such as a
            // watchdog or an outliving routine may themselves have been
            // created from a user-turn task.  A real empty snapshot freezes
            // "no selection" for the whole asynchronous body, including its
            // bounded child tasks.  Do NOT use `withValue(nil)` here — that
            // would make a later pending highlight appear in this old report.
            await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                    if let previous {
                        let waited = await bounded(chainWait) { () async -> Bool in
                            await previous.task.value
                            return true
                        }
                        if waited == nil {
                            // The predecessor is wedged. Speak anyway: a late answer
                            // out of order beats a correct order nobody ever hears —
                            // but SHUT IT FIRST, or it speaks into this entry's audio
                            // the moment it comes unstuck.
                            previous.gate.close()
                            previous.task.cancel()
                            channel.yield(.followUpCompleted(
                                fullText: "", originUserTurnID: previous.origin))
                            Self.laneLog.error("follow-up chain: stepped over a wedged predecessor")
                            ledger.record(ReadDelivery(
                                route: .chainStalled,
                                detail: "stepped over a wedged earlier follow-up",
                                characters: 0))
                        }
                    }
                    let ran = await bounded(bodyCap) { () async -> Bool in
                        await body(gate)
                        return true
                    }
                    if ran == nil {
                        // Same rule applied to THIS entry: `bounded` gave up on the
                        // body, so the body has lost its claim on the mouth. Without
                        // this the very next follow-up inherits a talker it never
                        // knew about.
                        gate.close()
                        channel.yield(.followUpCompleted(fullText: "", originUserTurnID: origin))
                        Self.laneLog.error("follow-up chain: a body ran past its budget")
                        ledger.record(ReadDelivery(
                            route: .chainStalled,
                            detail: "follow-up body ran past its budget",
                            characters: 0))
                    }
                }
            }
        }
        followUpChain = ChainEntry(task: task, gate: gate, origin: origin)
        // The CALLER is released on a deadline too — this is the await that
        // kept `.routineSettled` from ever firing.
        _ = await bounded(handoffBudget) { () async -> Bool in
            await task.value
            return true
        }
    }

    /// Speak an honest follow-up when a fire-and-forget code edit FAILED — a
    /// success lands silently (it just appears in Xcode). The app bridges
    /// `CodingAgentManager` completions here. Uses the same proactive channel
    /// finishRoutine does, but is a STANDALONE notification: it never touches
    /// the routine registry (the edit already returned "on it" in-turn and
    /// the lane joined; there is no routine to settle). Rides the follow-up
    /// chain so it can't interleave with a routine's spoken follow-up.
    /// `originUserTurnID` defaults nil — a STANDALONE notice: the app renders
    /// it as its own trailing bubble. Threading the real origin id through
    /// `CodingAgentManager.SessionInfo` is a noted follow-up; the seam is
    /// forward-compatible.
    public func emitCodingFollowUp(failureReason: String, originUserTurnID: UUID? = nil) async {
        let reason = failureReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = reason.isEmpty
            ? "Heads up — that last code change didn't go through."
            : "Heads up — I couldn't finish that code change. \(reason)"
        await enqueueFollowUp(origin: originUserTurnID) { [weak self] gate in
            guard gate.isOpen else { return }
            self?.proactiveYield(.followUpToken(line, originUserTurnID: originUserTurnID))
            self?.proactiveYield(.followUpCompleted(fullText: line, originUserTurnID: originUserTurnID))
        }
    }

    /// Nonisolated yield seam so chained closures can emit without awaiting
    /// the actor (ProactiveMulticast is lock-based).
    nonisolated func proactiveYield(_ event: ProactiveEvent) {
        proactive.yield(event)
    }
}

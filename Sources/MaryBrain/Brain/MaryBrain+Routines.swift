//
//  MaryBrain+Routines.swift
//  MaryBrain
//
//  WHAT: Detached-routine lifecycle — ActiveRoutine, LateRoutine, ChainEntry.
//  IN:   MaryBrain.swift registries
//  OUT:  progress / expire / finish / enqueueFollowUp
//  PIN:  Nested types are internal-for-split; treat as private.
//
import MaryAmbient
import MaryFoundation
import MaryVoice
import Foundation
import MaryComputerUse
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
        /// The world the SPAWNING turn was in — snapshot on the actor at detach, while `runTurn`'s utterance override is still installed.
        let originFocus: WorkspaceFocus?
        /// The user started a NEW topic while this routine ran — their moving
        /// on reads as "it landed, don't narrate it". All-ok outcomes settle
        /// silently; failures still speak regardless.
        var supersededByNewTurn: Bool = false
        /// FETCH-FIRST ALREADY DELIVERED this turn's passage.
        let servedByPreRead: Bool
        /// THE REVISION THIS ROUTINE IS, if it is one — carried for the same reason `servedByPreRead` is, and closing the same class of hole.
        let editIntent: EditIntent?
        let writingTarget: AmbientWritingTarget?
        let locatedTarget: LocatedPassage?
        /// WHEN THE LANE STARTED — the spawn instant, not the detach.
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

    /// Serializes spoken follow-ups: two background actions finishing near each other must speak one-after-another
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

    /// Releases ONE routine and its two clocks together — every terminal path (finish, expiry, bare-stop) goes through here so no half can outlive another.
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
    /// Returns the routine it stopped, or nil if it had already settled
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
    /// PIN: IT DOES NOT MERGE INTO HISTORY either, and that one is load-bearing: history is replayed to Seer on every later turn
    // internal for file split — treat as private
    func speakRoutineProgress(id: UUID) {
        guard let routine = activeRoutines[id] else { return }
        proactive.yield(.routineProgress(
            "Still working on \(routine.label) — I'll tell you the moment it lands.",
            originUserTurnID: routine.originUserTurnID))
    }

    /// Watchdog expiry: cancel the hung lane and say so.
    /// AN EXPIRED ROUTINE OWES AN HONEST FAILURE, not a disappearance.
    /// PIN: These lines are FIXED TEXT, which is exactly the case an exact-text guard decides soundly
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
        // Keep the entry — a late result after stop is still an answer.
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

    /// The follow-up chain: each spoken follow-up awaits every earlier one. Actor-isolated bookkeeping; the body runs on the actor as well.
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
            // The chain is the last line of defence: callers such as a watchdog or an outliving routine may themselves have been created from a user-turn task.
            await SchemaSignalTurnContext.$snapshot.withValue(.empty) {
                await AmbientSelectionTurnContext.$snapshot.withValue(.empty) {
                    if let previous {
                        let waited = await bounded(chainWait) { () async -> Bool in
                            await previous.task.value
                            return true
                        }
                        if waited == nil {
                            // The predecessor is wedged. Speak anyway: a late answer out of order beats a correct order nobody ever hears
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
                        // Same rule applied to THIS entry: `bounded` gave up on the body, so the body has lost its claim on the mouth.
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

    /// Speak an honest follow-up when a fire-and-forget code edit FAILED — a success lands silently (it just appears in Xcode).
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

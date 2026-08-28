//
//  MaryBrain+LanguageResponder.swift
//

import MaryAmbient
import MaryFoundation
import MaryVoice
import Foundation
import os

extension MaryBrain {


    // MARK: - LanguageResponder

    public nonisolated func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
        startTurn(userText: userText, superseding: false)
    }

    /// Amend flow: cancel the in-flight turn, remove its exchange from
    /// history, and run a fresh turn with the amended text. The epoch bumps
    /// BEFORE the old task is cancelled, so its late writes are dropped even
    /// while it unwinds inside a subprocess.
    public nonisolated func respondSuperseding(_ userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
        startTurn(userText: userText, superseding: true)
    }

    private nonisolated func startTurn(
        userText: String,
        superseding: Bool
    ) -> AsyncThrowingStream<BrainEvent, Error> {
        AsyncThrowingStream { continuation in
            let epoch = turnBox.reserve()
            let task = Task {
                await self.runTurn(
                    userText: userText,
                    continuation: continuation,
                    epoch: epoch,
                    superseding: superseding
                )
            }
            turnBox.install(task, for: epoch)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func cancel() async {
        turnBox.cancelCurrent()
    }

    /// Detached-routine progress + spoken follow-ups (LanguageResponder).
    public nonisolated func proactiveEvents() -> AsyncStream<ProactiveEvent> {
        proactive.subscribe()
    }

    /// A SPOKEN PROGRESS MARK NEVER REACHED THE EAR (LanguageResponder).
    ///
    /// THE FAILURE THIS MAKES VISIBLE: `speakRoutineProgress` is a hard, silent,
    /// one-shot gate — a mark that fires while the user is mid-utterance, or
    /// while audio is still draining, is consumed FOREVER, with no retry and no
    /// trace. The user chose to accept the drop ("worth hearing in the pause it
    /// describes and worth nothing fifteen seconds later"), and the timing is
    /// unchanged; what was never acceptable is that a routine could lose BOTH
    /// marks and sit silent from 0 to 420 s with no row anywhere saying two
    /// spoken promises had been destroyed.
    ///
    /// `.droppedStale` IS THE EXISTING WORD FOR THIS, not a new one. Its own
    /// doc quotes the same rule this gate enforces — "if the moment has passed
    /// it is DROPPED rather than spoken into the wrong context" — and the
    /// transcript still carries the routine under its own exchange, so it is
    /// exactly the ear that missed it. Inventing a parallel vocabulary for the
    /// second producer of one outcome is how a pane comes to disagree with a
    /// test about what happened.
    ///
    /// The `ProactiveEvent.routineProgress` doc forbids a progress line from
    /// booking a row, and that still holds for a line that SPEAKS: a delivered
    /// mark is not a read and must not overwrite the answer to "where did the
    /// read I just watched go?". A DROPPED one is a silence, and the ledger is
    /// the register of silences.
    public func noteProgressDropped(_ line: String) async {
        readLedger.record(ReadDelivery(
            route: .droppedStale,
            detail: "progress mark — \(line)",
            characters: 0))
    }

    /// Whether any detached routine is currently executing.
    public var isRoutineActive: Bool { !activeRoutines.isEmpty }
    /// How many detached routines are currently executing.
    public var activeRoutineCount: Int { activeRoutines.count }

    // MARK: - Stopping things

    /// ONE PIECE OF BACKGROUND WORK, as the app may show it.
    ///
    /// Only what a person can act on: what it is called, when it started, and
    /// which exchange it belongs to. Nothing about the lane, the prompt, or
    /// the outcomes — a Stop control is not a debugger.
    public struct RunningRoutine: Sendable, Identifiable {
        public let id: UUID
        public let label: String
        public let originUserTurnID: UUID
        public let spawnedAt: DispatchTime
    }

    /// The routines running right now. The registry has carried `label` since
    /// routines existed; this is the first thing to read it out.
    public var runningRoutines: [RunningRoutine] {
        activeRoutines.values.map {
            RunningRoutine(
                id: $0.id, label: $0.label,
                originUserTurnID: $0.originUserTurnID, spawnedAt: $0.spawnedAt)
        }
    }

    /// STOP ONE ROUTINE — what a Stop button on one row sends.
    ///
    /// Until now the only user-facing cancel was the spoken bare "stop", which
    /// halts EVERYTHING by explicit design ("one stop, no disambiguation
    /// grammar"). That decision was about the SPOKEN grammar — there is no
    /// ambiguity to resolve when a person has clicked one row — so this is not
    /// a reversal of it. Both go through `cancelRoutine(id:)`.
    ///
    /// The acknowledgement is empty: a click has already acknowledged itself,
    /// and speaking "Okay — I stopped it" at someone who is looking at the
    /// button they just pressed is the app talking to itself.
    public func stopRoutine(id: UUID) {
        cancelRoutine(id: id)
    }

    /// STOP EVERYTHING RUNNING IN THE BACKGROUND — the "Stop all" control,
    /// and the same tear-down the spoken bare "stop" performs.
    ///
    /// The paused typing remainder dies with it, and that is not incidental:
    /// stop must never leave something behind that a later "continue" would
    /// surprise-type into a document.
    ///
    /// Returns the labels it stopped so the caller can say what happened.
    @discardableResult
    public func stopAllRoutines() -> [String] {
        let stopped = activeRoutines.values.map(\.label)
        for id in Array(activeRoutines.keys) {
            cancelRoutine(id: id)
        }
        PausedTypingSession.clear()
        return stopped
    }

    /// STOP ONE CALL, by the id its chip shows.
    ///
    /// Narrower than stopping a routine: the lane keeps going and may well
    /// dispatch something else. That is the right granularity for a Stop on a
    /// single run row — the person is objecting to one act, not to the whole
    /// request.
    public func stopRun(id: String) {
        dispatcher?.cancelRun(id: id)
    }

}

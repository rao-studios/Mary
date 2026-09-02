//
//  MaryBrain+LanguageResponder.swift
//  MaryBrain
//
//  WHAT: LanguageResponder surface — respond / amend / startTurn.
//  IN:   VoicePipeline / SendText
//  OUT:  AsyncThrowingStream<BrainEvent>
//  PIN:  Signaled from MaryVoice; starts a turn.
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

    /// Amend flow: cancel the in-flight turn, remove its exchange from history, and run a fresh turn with the amended text.
    public nonisolated func respondSuperseding(_ userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
        startTurn(userText: userText, superseding: true)
    }

    // ROUTE: signaled from MaryVoice, starts a turn
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
    public func stopRoutine(id: UUID) {
        cancelRoutine(id: id)
    }

    /// STOP EVERYTHING RUNNING IN THE BACKGROUND — the "Stop all" control, and the same tear-down the spoken bare "stop" performs.
    /// Returns the labels it stopped so the caller can say what happened.
    /// PIN: The paused typing remainder dies with it, and that is not incidental: stop must never leave something behind that a…
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
    public func stopRun(id: String) {
        dispatcher?.cancelRun(id: id)
    }

}

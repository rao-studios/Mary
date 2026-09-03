//
//  LifeCalibrationViewModel.swift
//  Mary
//
//  WHAT: What the idle engine is doing, plus per-discipline calibration.
//  PIN:  Engine state arrives on its event stream — the poll is only for the
//        episode-count bars, which come from Totem, not from the engine.
//

import Foundation
import SwiftUI
import MaryBrain
import MaryRuntime

@MainActor
final class LifeCalibrationViewModel: ObservableObject {

    @Published var snapshot = LifeCalibrationSnapshot(rows: [], fleetReachable: true)
    @Published var engine = LifeEngineSnapshot()
    @Published var expandedID: String?
    @Published var expandedDecisionID: UUID?
    /// Set while a manual pulse is in flight, so the button can say so.
    @Published var pulsing = false
    /// Disciplines allowed to answer a live turn.
    @Published private(set) var turnDisciplines: Set<String> = []

    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        Task { await MaryRuntime.refreshReadyLoRAs() }
        Task { await MaryRuntime.refreshBehaviorEpisodesFromTotem() }
        eventTask = Task { [weak self] in
            let stream = await MaryRuntime.lifeEngineEvents()
            // Seed before the first event so an idle engine still renders.
            await self?.refreshEngine()
            for await _ in stream {
                guard let self, !Task.isCancelled else { return }
                await self.refreshEngine()
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.snapshot = await MaryRuntime.lifeCalibration()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func refreshEngine() async {
        engine = await MaryRuntime.lifeEngineSnapshot()
        turnDisciplines = await MaryRuntime.lifeTurnDisciplines()
    }

    func setMode(_ mode: LifeMode) {
        Task {
            await MaryRuntime.setLifeMode(mode)
            await refreshEngine()
        }
    }

    /// Infer once and record it, dispatching nothing — the way to watch the
    /// engine think without letting it touch anything.
    func pulseDryRun() {
        guard !pulsing else { return }
        pulsing = true
        Task {
            await MaryRuntime.lifePulseNow(dryRun: true)
            await refreshEngine()
            pulsing = false
        }
    }

    /// Whether this discipline's adapter may answer a live turn.
    func answersTurns(_ abilityID: String) -> Bool {
        turnDisciplines.contains(abilityID)
    }

    func setAnswersTurns(_ abilityID: String, _ on: Bool) {
        if on { turnDisciplines.insert(abilityID) } else { turnDisciplines.remove(abilityID) }
        let next = turnDisciplines
        Task { await MaryRuntime.setLifeTurnDisciplines(next) }
    }

    func toggleExpanded(_ id: String) {
        expandedID = expandedID == id ? nil : id
    }

    func toggleDecision(_ id: UUID) {
        expandedDecisionID = expandedDecisionID == id ? nil : id
    }
}

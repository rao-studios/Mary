//
//  LifeCalibrationViewModel.swift
//  Mary
//
//  WHAT: 1 Hz Life snapshot while calibration sheet is open.
//  PIN:  One listAdapters + one Totem export on start; poll never dials Fleet/Totem.
//

import Foundation
import SwiftUI
import MaryRuntime

@MainActor
final class LifeCalibrationViewModel: ObservableObject {

    @Published var snapshot = LifeCalibrationSnapshot(rows: [], fleetReachable: true)
    @Published var expandedID: String?

    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        Task { await MaryRuntime.refreshReadyLoRAs() }
        Task { await MaryRuntime.refreshBehaviorEpisodesFromTotem() }
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
    }

    func toggleExpanded(_ id: String) {
        expandedID = expandedID == id ? nil : id
    }
}

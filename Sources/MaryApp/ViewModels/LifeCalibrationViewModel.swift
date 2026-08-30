//
//  LifeCalibrationViewModel.swift
//  Mary
//
//  1 Hz poll of the Life snapshot while the calibration sheet is open.
//  One listAdapters refresh on start — the poll itself never dials Fleet.
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

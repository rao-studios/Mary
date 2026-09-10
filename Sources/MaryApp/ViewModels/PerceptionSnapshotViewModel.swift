//
//  PerceptionSnapshotViewModel.swift
//  Mary
//
//  WHAT: Watcher lock-boxes + focus → debugger (500 ms poll).
//  OUT:  PerceptionCard via gather() / buildCards() / buildFocus()
//  PIN:  Never Granite @Store. gather() is the only impure read.
//

import AppKit
import ApplicationServices
import MaryBrain
import MaryPlugin
import SwiftUI
import MaryRuntime

@MainActor
final class PerceptionSnapshotViewModel: ObservableObject {

    @Published internal(set) var cards: [PerceptionCard] = []
    @Published internal(set) var focus = FocusSummary(
        ambient: nil, effective: nil, overrideActive: false)

    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

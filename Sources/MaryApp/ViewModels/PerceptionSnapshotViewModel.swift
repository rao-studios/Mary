//
//  PerceptionSnapshotViewModel.swift
//  Mary
//
//  Bridges the watcher lock-boxes + focus tracker to the debugger pane —
//  500 ms poll, AbilityExecutionLogViewModel's shape, started/stopped by the pane's
//  appear/disappear. NEVER Granite @Store: the 200 ms debounce would blur a
//  realtime inspector (the standing doctrine — Debugger.Center holds only
//  click-scoped state). The core is pure: gather() does every impure read,
//  buildCards()/buildFocus() are table-testable functions of Inputs.
//

import AppKit
import ApplicationServices
import MaryBrain
import MaryAdapters
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

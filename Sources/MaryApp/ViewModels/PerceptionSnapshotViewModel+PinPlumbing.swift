//
//  PerceptionSnapshotViewModel+PinPlumbing.swift
//

import AppKit
import ApplicationServices
import MaryBrain
import MaryPlugin
import SwiftUI
import MaryRuntime

extension PerceptionSnapshotViewModel {

    // MARK: - Pin plumbing

    // The ONLY writers of the pin in the process, so the published state
    // after each call is exact, not eventually-consistent.

    func togglePin(_ world: PerceptionWorld) {
        guard world.hasLiveObserver else { return }
        // No pin for a place with no discipline.
        guard let pin = world.pinnedWorld else { return }
        if WorkspaceFocusTracker.shared.pinned() == pin {
            WorkspaceFocusTracker.shared.clearPin()
        } else {
            WorkspaceFocusTracker.shared.pin(pin)
        }
        refresh()
    }

    func clearPin() {
        WorkspaceFocusTracker.shared.clearPin()
        refresh()
    }

    /// Recognized debugger-card identity for a window. This intentionally
    /// returns Keynote so its explicit unavailable card remains inspectable;
    /// `hasLiveObserver` is the separate pin/watch gate.
    nonisolated static func world(forBundleID id: String?) -> PerceptionWorld? {
        guard let pinned = PinnedWorld.from(bundleID: id) else { return nil }
        return PerceptionWorld.current().first { $0.pinnedWorld == pinned }
    }

}

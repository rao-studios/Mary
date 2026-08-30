//
//  PerceptionSnapshotViewModel+Helpers.swift
//

import AppKit
import ApplicationServices
import MaryBrain
import MaryPlugin
import SwiftUI

extension PerceptionSnapshotViewModel {

    // MARK: - Helpers

    nonisolated static func cadence(active: TimeInterval, idle: TimeInterval) -> String {
        String(format: "%.1fs active / %.1fs idle", active, idle)
    }

    nonisolated static func cap(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(0, limit - 1))) + "…"
    }

}

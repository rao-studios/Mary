//
//  PerceptionSnapshotViewModel+Refresh.swift
//

import AppKit
import ApplicationServices
import MaryBrain
import MaryPlugin
import SwiftUI

extension PerceptionSnapshotViewModel {

    // MARK: - Refresh

    func refresh() {
        let inputs = Self.gather()
        let builtCards = Self.buildCards(inputs)
        if builtCards != cards { cards = builtCards }   // Equatable diff — no churn repaints
        let builtFocus = Self.buildFocus(inputs)
        if builtFocus != focus { focus = builtFocus }
    }

}

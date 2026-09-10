//
//  PerceptionSnapshotViewModel+Gather.swift
//  Mary
//
//  WHAT: Impure read of the live world into Inputs (roster, not named watchers).
//  OUT:  PerceptionSnapshotViewModel.build*
//

import AppKit
import Foundation
import MaryPlugin
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryRuntime

extension PerceptionSnapshotViewModel {

    nonisolated static func gather(at now: Date = Date()) -> Inputs {
        let index = AmbientApplicationIndexProvider.current
        let store = AmbientContextStore.shared
        let tracker = WorkspaceFocusTracker.shared
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        var inputs = Inputs()
        inputs.now = now
        inputs.axTrusted = AXIsProcessTrusted()
        inputs.ambient = tracker.current()
        inputs.effective = tracker.effectiveFocus()
        inputs.writingPlace = tracker.writingPlace()
        inputs.pinned = tracker.pinned()
        inputs.writingInPlay = tracker.writingInPlay()
        // Override inferred (override ?? pin ?? ambient), not a stored flag.
        inputs.overrideActive = inputs.effective != (inputs.pinned?.focus ?? inputs.ambient)
        inputs.facts = store.facts()
        inputs.readDelivery = ReadDeliveryLedger.shared.latest()
        inputs.rankingMode = store.route()?.rankingMode ?? .relevance

        for registration in index.all.sorted(by: { $0.id < $1.id }) {
            let world = PerceptionWorld(registration.place)
            inputs.surfaces[registration.place] = store.surface(
                place: registration.place, at: now)
            let isRunning = registration.bundleIdentifiers.contains { bundleID in
                running.contains { $0 == bundleID || $0.hasPrefix(bundleID) }
            }
            inputs.observed.append(Inputs.Observed(
                world: world,
                isRunning: isRunning,
                isActive: registration.hasEyes,
                // Contribution is the observer's surface line from the store.
                contribution: inputs.surfaces[registration.place]?.surfaceLine(at: now),
                capturedAt: inputs.surfaces[registration.place]?.capturedAt,
                // Blindness the pane can prove: Accessibility off (not-running is its own field).
                blindness: inputs.axTrusted ? nil : .accessibilityLimited,
                pollDescription: registration.perception.map {
                    "every \($0.pollSeconds)s"
                } ?? "on demand"))
        }
        return inputs
    }

    /// The card a window tile belongs to.
    nonisolated static func world(forBundleID bundleID: String) -> PerceptionWorld? {
        AmbientApplicationIndexProvider.current
            .registration(bundleID: bundleID)
            .map { PerceptionWorld($0.place) }
    }
}

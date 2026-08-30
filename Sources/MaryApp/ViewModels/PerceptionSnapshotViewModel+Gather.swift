//
//  PerceptionSnapshotViewModel+Gather.swift
//  Mary
//
//  READING THE LIVE WORLD INTO `Inputs` — the one impure function in the
//  perception pane, kept alone so everything downstream of it is testable.
//
//  IT ASKS THE ROSTER, and that is the whole difference from what it replaces.
//  Its predecessor read five named watchers plus a list for anything taught,
//  so a pane that was supposed to show "everything Mary can see" showed
//  whatever somebody had wired a field for. This enumerates registrations,
//  which is the same set the turn loop enumerates — the pane and the turn
//  cannot disagree about what exists.
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
        // AN OVERRIDE IS INFERRED, NOT READ: the effective focus is
        // `override ?? pin ?? ambient`, so any disagreement with the tier
        // below IS one. Almost always false — the pane is open between
        // turns, when overrides are cleared.
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
                // THE SURFACE LINE IS THE CONTRIBUTION. A place contributes
                // when something is actually looking at it and saw something
                // — which is what the observer publishes, and asking the
                // store for it is how the pane reads the same fact the prompt
                // does rather than a second one computed here.
                contribution: inputs.surfaces[registration.place]?.surfaceLine(at: now),
                capturedAt: inputs.surfaces[registration.place]?.capturedAt,
                // BLINDNESS THE PANE CAN PROVE. Accessibility off is a fact
                // about Mary; "not running" is a fact about the application
                // and is already its own field. Anything subtler than these
                // two would be the pane guessing, which is the one thing a
                // debugger must not do.
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

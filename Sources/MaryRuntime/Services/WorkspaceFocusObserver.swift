//
//  WorkspaceFocusObserver.swift
//  MaryRuntime
//
//  WHAT: NSWorkspace didActivate → instant coding/writing focus (not 1.5–20s polls).
//  OUT:  WorkspaceFocusTracker. Lives here, not MaryBrain — probes stay poll-fed.
//

import AppKit
import MaryBrain
import MaryPlugin

package enum WorkspaceFocusObserver {

    private nonisolated(unsafe) static var activationToken: NSObjectProtocol?
    private nonisolated(unsafe) static var deactivationToken: NSObjectProtocol?
    private nonisolated(unsafe) static var terminationToken: NSObjectProtocol?
    private nonisolated(unsafe) static var spaceToken: NSObjectProtocol?

    package static func installOnce() {
        guard activationToken == nil else { return }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let applicationID = app?.bundleIdentifier
            WorkspaceFocusTracker.shared.record(
                bundleID: applicationID, localizedName: app?.localizedName)
            if applicationID == Bundle.main.bundleIdentifier {
                SelectionHandoffCoordinator.shared.noteComposerActivated()
            } else {
                SelectionHandoffCoordinator.shared.noteSourceActivated(
                    applicationID: applicationID)
                // Source selection is a request handoff, not ambient that follows the user.
                AmbientContextStore.shared.revokeUnclaimedSelectionForExternalActivation(
                    applicationID: applicationID,
                    processID: app.map { Int32($0.processIdentifier) })
            }
        }
        // Not a focus-routing signal — arms a short source-owned handoff only.
        deactivationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            SelectionHandoffCoordinator.shared.noteSourceDeactivated(
                applicationID: app?.bundleIdentifier)
        }
        // Process terminate invalidates surfaces. Watcher stop is not the end of a selection.
        terminationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard let applicationID = app?.bundleIdentifier else { return }
            AmbientContextStore.shared.clearSelection(
                applicationID: applicationID,
                processID: app.map { Int32($0.processIdentifier) },
                allSurfaces: true)
            // Process quit: drop document facts, stand the tracker down. One branch for all places.
            if let registration = AmbientApplicationIndexProvider.current
                .registration(bundleID: applicationID) {
                AmbientContextStore.shared.forgetPerceived(place: registration.place)
            }
            // A quit registered dynamic app stops asserting the lead — the
            // ambient evidence must not outlive the process.
            if let registration = AmbientApplicationIndexProvider.current
                .registration(bundleID: applicationID),
               registration.place.application != nil {
                WorkspaceFocusTracker.shared.clearLead(ifApplication: registration.id)
            } else if AmbientPlaceResolver.isBrowser(bundleID: applicationID) {
                // The browser workspace's claim ends only when NO browser
                // remains running — Chrome quitting while Safari stays is
                // still "the user has a browser workspace".
                let stillRunning = NSWorkspace.shared.runningApplications
                    .contains { running in
                        guard let id = running.bundleIdentifier,
                              id != applicationID else { return false }
                        return AmbientPlaceResolver.isBrowser(bundleID: id)
                    }
                if !stillRunning {
                    WorkspaceFocusTracker.shared.clearLead(
                        ifApplication: AmbientPlaceResolver.browserApplicationID)
                }
                AmbientApplicationDirectory.shared.evict(bundleID: applicationID)
            } else {
                // A generic app's place carries its bundle id (cursor-obvious
                // lead) — the exact match the identity decision bought.
                WorkspaceFocusTracker.shared.clearLead(ifApplication: applicationID)
                AmbientApplicationDirectory.shared.evict(bundleID: applicationID)
            }
            SelectionHandoffCoordinator.shared.noteSourceTerminated(
                applicationID: applicationID)
        }
        // Space change: resample frontmost (didActivate may not fire).
        spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            WorkspaceFocusTracker.shared.sample()
        }
        // Seed from current frontmost — didActivate only fires on the next switch.
        WorkspaceFocusTracker.shared.sample()
        // Seed the lifecycle handoff coordinator — not a workspace-focus decision.
        let initialSource = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if initialSource != Bundle.main.bundleIdentifier {
            SelectionHandoffCoordinator.shared.noteSourceActivated(
                applicationID: initialSource)
        }
    }
}

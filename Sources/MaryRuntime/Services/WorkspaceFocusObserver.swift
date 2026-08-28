//
//  WorkspaceFocusObserver.swift
//  Mary
//
//  App-layer feed for the coding/writing focus arbiter: NSWorkspace's
//  didActivate notification gives INSTANT transitions (the watcher poll
//  loops sample at 1.5–20s, too slow for "alt-tab and speak"). Lives here,
//  not in MaryBrain — observers are app machinery, and headless probes
//  (which never call this) stay purely poll-fed and deterministic.
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
                // A raw source selection is one request handoff, not ambient
                // context that follows the user from TextEdit into Safari.
                // Do this at the external activation boundary, after the
                // coordinator has revoked its lifecycle retry, so neither a
                // queued deactivation nor a slow AX read can arm the old
                // source for a later Mary request.
                AmbientContextStore.shared.revokeUnclaimedSelectionForExternalActivation(
                    applicationID: applicationID,
                    processID: app.map { Int32($0.processIdentifier) })
            }
        }
        // This is deliberately NOT a focus-routing signal. An app yielding
        // focus merely arms its short source-owned handoff. The actual AX read
        // waits until Mary has activated and is about to begin a turn; a
        // deactivation callback can otherwise confuse an ordinary TextEdit ->
        // Safari switch for a request handoff.
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
        // A watcher stopping is not evidence that the source selection ended;
        // a process actually terminating is. This is the explicit lifecycle
        // boundary that invalidates every surface from that process rather
        // than making plugin teardown erase an otherwise usable handoff.
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
            // A process boundary also invalidates that representation's
            // document facts immediately. Selection is cleared separately
            // above because it is source-owned; this only prevents a just-
            // terminated Pages/TextEdit/Scrivener/Xcode snapshot reaching the
            // next hands-free request before its watcher gets another tick.
            // A NATIVE QUIT also stands the tracker down (clearNative): the
            // lead, the ledger entry, and the coding/writing box when the
            // signal belonged to the quitting app — a quit Xcode's `.coding`
            // used to stand for 20 minutes and lead unrelated turns.
            // A QUIT PLACE STOPS ASSERTING ANYTHING, and there is one branch
            // for all of them.
            //
            // Four hand-written arms used to stand here, one per compiled
            // application, each forgetting that application's perceived facts
            // and standing its focus box down — so a taught application that
            // quit left its facts and its lead in place, and a stale snapshot
            // led unrelated turns for the twenty minutes until it decayed.
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
        // SPACES: switching desktops changes what "frontmost" means without
        // necessarily firing didActivate (and the watcher polls are 1.5-10s
        // behind). One sample per Space change keeps the cursor-obvious lead
        // exactly where the user's cursor went.
        spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            WorkspaceFocusTracker.shared.sample()
        }
        // Seed from whatever is frontmost right now — didActivate only fires
        // on the NEXT switch, so without this a launch with Xcode/Scrivener
        // already frontmost leaves focus nil (→ coding-first) until you
        // re-activate the app.
        WorkspaceFocusTracker.shared.sample()
        // The first source window may already be open when Mary launches,
        // so there may be no future activation event before the user selects
        // text and invokes the composer. Seed only the lifecycle handoff
        // coordinator; it is not a workspace-focus decision.
        let initialSource = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if initialSource != Bundle.main.bundleIdentifier {
            SelectionHandoffCoordinator.shared.noteSourceActivated(
                applicationID: initialSource)
        }
    }
}

//
//  WorkspaceFocusTracker.swift
//  MaryBrain
//
//  WHAT: Which place the user is in — most recent activity, not a glance.
//  IN:   poll sample() / NSWorkspace didActivate / watcher note(...)
//  OUT:  lead → AmbientContextStore. Overlays: named discipline > PinnedWorld > ambient
//  PIN:  Mary's window, Terminal, a browser leave the signal alone unless they earn a place.
//

import AppKit
import Foundation
import os


public final class WorkspaceFocusTracker: Sendable {

    public static let shared = WorkspaceFocusTracker()

    let box = OSAllocatedUnfairLock<(focus: WorkspaceFocus, at: Date)?>(initialState: nil)
    /// Turn-scoped override from the utterance; overlays `current()` via
    /// `effectiveFocus()`. Set at the top of a turn, cleared when it ends.
    let overrideBox = OSAllocatedUnfairLock<WorkspaceFocus?>(initialState: nil)
    /// While set (and in the future), every signal is ignored — see suppress().
    let suppressBox = OSAllocatedUnfairLock<Date?>(initialState: nil)
    /// WHERE THE WRITING SIGNAL CAME FROM — nil until one arrives.
    let writingPlaceBox = OSAllocatedUnfairLock<AmbientPlace?>(initialState: nil)
    /// User-planted pin; overlays ambient below the turn override. NOT gated
    /// by signalsAllowed() — a debugger click is user intent, not a ceremony
    /// echo, so it lands even mid-suppress/mid-self-driving.
    let pinBox = OSAllocatedUnfairLock<PinnedWorld?>(initialState: nil)
    /// Live self-driving holds (Mary typing, a menu ceremony) — while ANY
    /// hold is open, signals are ignored regardless of the deadline above.
    let holdsBox = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])
    /// WHICH REALM last asserted the lead — ONE box for both cases of the identity. The native
    /// arms of `record(bundleID:)` and the watchers' real-work signals stamp `.lane(attention)`; a
    /// registered dynamic application's activation/activity stamps its registration's place.
    let leadBox =
        OSAllocatedUnfairLock<(place: AmbientPlace, at: Date)?>(initialState: nil)
    /// Per-app canvas-selection baseline for change detection — a standing
    /// selection re-reported every poll is not an interaction.
    let selectionBox =
        OSAllocatedUnfairLock<(id: String, signature: String)?>(initialState: nil)
    /// THE EVIDENCE LEDGER behind the single lead — one freshest stamp per place, written by
    /// the same funnels that stamp `leadBox` plus the glance responder. `leadBox` stays
    /// authoritative for the lead; `signal()` projects this into the co-active set.
    let ledgerBox =
        OSAllocatedUnfairLock<[AmbientPlace: FocusEvidence]>(initialState: [:])
    /// Declared editor pane for look_at_screen — identity + frame, not a lead.
    let paneBox = OSAllocatedUnfairLock<FocusPaneTarget?>(initialState: nil)

    public init() {}

    /// TCC-free frontmost read; polling NSWorkspace has precedent
    /// (`ApplicationMenuDriver`) — no observers inside MaryBrain.
    public func sample() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        record(
            bundleID: frontmost?.bundleIdentifier,
            localizedName: frontmost?.localizedName)
    }

    /// BUNDLES THAT MUST NEVER DISPLACE THE LEAD: Mary's own window (the user speaking to Mary
    /// is not a workspace change), and system chrome whose activation is an artifact, not a
    /// destination. Prefix-matched.
    public static let leadExcludedBundlePrefixes: [String] = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver",
        "com.apple.dock",
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.SecurityAgent",
    ]
    public static let finderBundleID = "com.apple.finder"

    /// Mary's overlay and system chrome do not count as leaving a workspace. A nil bundle — no
    /// frontmost process at all — is the same situation: the user is speaking to Mary, not
    /// working in a different application.
    public static func isWorkspaceTransparent(
        bundleID: String?,
        maryBundleID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let bundleID else { return true }
        if let maryBundleID, bundleID == maryBundleID { return true }
        return leadExcludedBundlePrefixes.contains(where: bundleID.hasPrefix)
    }

    /// Map a bundle id to a focus and record it. sample() and the app-layer activation observer
    /// both funnel here. Bundle ids are owned by their domain plugins ; the tracker owns only
    /// the mapping. THE LADDER IS COMPLETE NOW : the app the user activates leads.
    public func record(bundleID: String?, localizedName: String? = nil) {
        guard let bundleID, signalsAllowed() else { return }
        // Mary's own window and system chrome never displace.
        if Self.isWorkspaceTransparent(bundleID: bundleID) { return }
        // NO COMPILED-APPLICATION ARMS.
        if AmbientPlaceResolver.isBrowser(bundleID: bundleID) {
            // THE BROWSER IS A WORKSPACE , and it LEADS . ABOVE the registration arm on purpose ): a
            // dynamic package may register a browser bundle (chrome.mary), but a Chrome activation
            // must keep stamping the ONE browser workspace with its concrete process id.
            AmbientApplicationDirectory.shared.note(
                bundleID: bundleID, name: localizedName)
            leadBox.withLock { $0 = (AmbientPlaceResolver.browserPlace, Date()) }
            stampEvidence(
                place: AmbientPlaceResolver.browserPlace, kind: .activation,
                processBundleID: bundleID)
            AmbientContextStore.shared.noteWorld(.init(
                sense: .workspace, attention: .applications,
                subject: AmbientPlaceResolver.browserApplicationID,
                applicationID: AmbientPlaceResolver.browserApplicationID))
        } else if let registration = AmbientApplicationIndexProvider.current
                      .registration(bundleID: bundleID),
                  registration.legacyAttention == nil {
            // A registered DYNAMIC application (Sketch) is a workspace the user can evidently be in,
            // exactly like the four native arms above. A TAUGHT APPLICATION WITH EYES IS A WRITING
            // WORKSPACE, not just an activation: an activation stamps the lead and stops.
            if registration.hasEyes, let focus = registration.place.focus {
                note(focus, place: registration.place)
            }
            noteDynamicApplication(registration.id)
        } else if bundleID == Self.finderBundleID {
            // FINDER: evidence only, never the lead (user decision — a
            // desktop misclick activates it constantly).
            stampEvidence(
                place: AmbientPlaceResolver.applicationPlace(forBundleID: bundleID),
                kind: .activation, processBundleID: bundleID)
        } else {
            // THE TERMINAL ARM — every generic app. The user activated it;
            // cursor-obvious means it leads, carrying its own identity (the
            // bundle id; display name via the directory).
            noteGenericApplication(bundleID: bundleID, localizedName: localizedName)
        }
    }

}

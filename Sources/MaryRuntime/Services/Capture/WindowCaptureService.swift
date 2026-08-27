//
//  WindowCaptureService.swift
//  Mary
//
//  Mary's literal eyes: ScreenCaptureKit window enumeration + per-window
//  thumbnails across ALL Spaces. Lives app-side (macOS 15, Screen-Recording-
//  gated) — MaryBrain stays TCC-cheap and headless-safe, the same doctrine
//  that keeps WorkspaceFocusObserver out of the probes. Captures ONLY while
//  the Debugger pane is polling; no pane, no WindowServer traffic.
//

import CoreGraphics
import Foundation
import ScreenCaptureKit

package actor WindowCaptureService {

    /// The pruned thumbnail cache — the whole memory story (~15 MB ceiling
    /// at 40 windows; closed windows drop every sweep).
    private var thumbnails: [CGWindowID: (image: CGImage, at: Date)] = [:]
    /// What the last screenshot of each window actually did. Kept SEPARATE
    /// from `thumbnails` because the interesting states are exactly the ones
    /// with no image: a throw and a successful capture of a window with
    /// nothing drawn in it used to be the same absence.
    private var captureStates: [CGWindowID: WindowCaptureState] = [:]
    private var requestFired = false

    /// One sweep: preflight → enumerate → filter/group (pure) → refresh a
    /// staggered batch of thumbnails → merged model. On preflight failure the
    /// caller builds the NSWorkspace roster (NSRunningApplication is main-
    /// thread machinery; this actor never touches AppKit).
    ///
    /// `uncappedGroupID` / `captureGroupIDs` carry the filter bar's selection
    /// down to where it actually costs something. Both are defaulted so the
    /// unfiltered sweep is unchanged.
    package func poll(
        visibleWindowIDs: Set<CGWindowID>,
        frontmostBundleID: String?,
        watchedBundleIDs: [String],
        watchedBundlePrefixes: [String],
        uncappedGroupID: String? = nil,
        captureGroupIDs: Set<String>? = nil
    ) async -> MinimapModel {
        // Preflight EVERY poll — a mid-session grant upgrades automatically,
        // and an unauthorized SCShareableContent call throws with system log
        // noise, so denial never touches SCK at all.
        guard CGPreflightScreenCaptureAccess() else {
            return MinimapModel(
                mode: .degraded(.screenRecordingDenied), groups: [], sweptAt: Date())
        }

        let content: SCShareableContent
        do {
            // The all-Spaces path: onScreenWindowsOnly false keeps windows on
            // other Spaces and hidden apps in the enumeration.
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
        } catch {
            return MinimapModel(
                mode: .degraded(.enumerationFailed(error.localizedDescription)),
                groups: [], sweptAt: Date())
        }

        var infos: [WindowInfo] = []
        var scWindows: [CGWindowID: SCWindow] = [:]
        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            infos.append(WindowInfo(
                id: window.windowID,
                pid: app.processID,
                bundleID: app.bundleIdentifier.isEmpty ? nil : app.bundleIdentifier,
                appName: app.applicationName,
                title: window.title,
                frame: window.frame,
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen,
                // The one property this boundary used to drop. Off-Space AND
                // active is Stage Manager doing its job; off-Space, inactive
                // and never-rendered is a husk.
                isActive: window.isActive))
            scWindows[window.windowID] = window
        }

        // NEVER filtered: the filter narrows what gets PHOTOGRAPHED, never
        // what gets enumerated — the pane's tab bar is built out of
        // `model.groups`, so an app that vanishes from the sweep vanishes
        // from the bar and can never be filtered back to.
        let eligible = WindowTileBuilder.eligible(infos, ownPID: getpid())
        var groups = WindowTileBuilder.groups(
            eligible,
            frontmostBundleID: frontmostBundleID,
            watchedBundleIDs: watchedBundleIDs,
            watchedBundlePrefixes: watchedBundlePrefixes,
            uncappedGroupID: uncappedGroupID)

        // Refresh a staggered batch — scroll-visible tiles first, then the
        // stalest. SEQUENTIAL, never parallel: one in-flight screenshot at a
        // time keeps WindowServer pressure flat. The candidate list is where
        // the capture scope lands: in `.filtered` the whole budget goes to
        // the tab in view (a Pages tile refreshes several times faster).
        let shownIDs = WindowTileBuilder.captureCandidates(groups, scopedTo: captureGroupIDs)
        let batch = WindowTileBuilder.refreshBatch(
            candidates: shownIDs,
            visible: visibleWindowIDs,
            lastCaptured: thumbnails.mapValues(\.at),
            budget: WindowTileBuilder.captureBudgetPerTick)
        for id in batch {
            guard let scWindow = scWindows[id] else { continue }
            // desktopIndependentWindow captures the window even off the
            // active Space.
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let size = WindowTileBuilder.thumbnailPixelSize(for: scWindow.frame)
            config.width = size.width
            config.height = size.height
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.scalesToFit = true
            // `shouldBeOpaque` stays UNSET on purpose. Setting it would paint
            // an unrendered window's transparent surface white and destroy
            // the only signal that says "this window has no backing store" —
            // which is the exact question the ghost tile raised.
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                let state = WindowCaptureProbe.classify(image)
                captureStates[id] = state
                if state == .captured {
                    thumbnails[id] = (image, Date())
                } else {
                    // A featureless surface is NOT a thumbnail. Storing it
                    // drew a blank rectangle that looked identical to a
                    // never-photographed tile; dropping it lets the pane say
                    // what actually happened.
                    thumbnails[id] = nil
                }
            } catch {
                // Minimized windows and close races throw — the tile keeps
                // its last thumbnail (age visible) or the icon card. Never a
                // broken pane. The reason is RECORDED now instead of being
                // bound and discarded: "it threw" and "it came back empty"
                // are different diagnoses of a blank tile.
                captureStates[id] = .failed(error.localizedDescription)
            }
        }

        // Per-sweep prune keyed on the current enumeration: closed windows
        // drop, and recycled CGWindowIDs can't wear a dead window's pixels.
        let enumerated = Set(infos.map(\.id))
        thumbnails = thumbnails.filter { enumerated.contains($0.key) }
        captureStates = captureStates.filter { enumerated.contains($0.key) }

        // Merge the cache into the tiles.
        for groupIndex in groups.indices {
            for tileIndex in groups[groupIndex].windows.indices {
                let id = groups[groupIndex].windows[tileIndex].id
                if let cached = thumbnails[id] {
                    groups[groupIndex].windows[tileIndex].thumbnail = cached.image
                    groups[groupIndex].windows[tileIndex].capturedAt = cached.at
                }
                if let state = captureStates[id] {
                    groups[groupIndex].windows[tileIndex].captureState = state
                }
            }
        }
        return MinimapModel(mode: .live, groups: groups, sweptAt: Date())
    }

    /// The first-open ceremony: CGRequestScreenCaptureAccess once per app
    /// launch — the dialog points at System Settings, the grant lands after
    /// relaunch (banner copy says so), and asking also registers Mary in
    /// the Screen Recording pane's list. Never nags twice.
    package func requestAccessIfNeverAsked() {
        guard !requestFired else { return }
        requestFired = true
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
    }
}

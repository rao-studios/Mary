//
//  WindowCaptureService.swift
//  MaryRuntime
//
//  WHAT: ScreenCaptureKit enumeration + per-window thumbnails across Spaces.
//  IN:   Debugger pane polling (no pane → no WindowServer traffic)
//  OUT:  WindowTileModel rules; maps SCWindow → WindowInfo at the boundary
//  PIN:  App-side (macOS 15, Screen Recording). MaryBrain stays TCC-cheap.
//

import CoreGraphics
import Foundation
import ScreenCaptureKit

package actor WindowCaptureService {

    /// The pruned thumbnail cache — the whole memory story (~15 MB ceiling
    /// at 40 windows; closed windows drop every sweep).
    private var thumbnails: [CGWindowID: (image: CGImage, at: Date)] = [:]
    /// Last screenshot outcome per window. Separate from thumbnails — throw vs blank.
    private var captureStates: [CGWindowID: WindowCaptureState] = [:]
    private var requestFired = false

    /// One sweep: preflight → enumerate → filter/group → staggered thumbnails.
    /// Preflight fail → caller builds NSWorkspace roster (this actor never touches AppKit).
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
                // isActive: off-Space+active is Stage Manager; inactive+never-rendered is a husk.
                isActive: window.isActive))
            scWindows[window.windowID] = window
        }

        // Never filter enumeration — model.groups feeds the tab bar.
        let eligible = WindowTileBuilder.eligible(infos, ownPID: getpid())
        var groups = WindowTileBuilder.groups(
            eligible,
            frontmostBundleID: frontmostBundleID,
            watchedBundleIDs: watchedBundleIDs,
            watchedBundlePrefixes: watchedBundlePrefixes,
            uncappedGroupID: uncappedGroupID)

        // Staggered batch, sequential — one screenshot at a time. Filtered: budget on tab in view.
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
            // shouldBeOpaque stays unset — transparent = never drawn, not white fill.
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                let state = WindowCaptureProbe.classify(image)
                captureStates[id] = state
                if state == .captured {
                    thumbnails[id] = (image, Date())
                } else {
                    // Featureless surface is not a thumbnail — drop it so the pane can say so.
                    thumbnails[id] = nil
                }
            } catch {
                // Throw keeps last thumbnail. Record the reason — throw vs empty differ.
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

    /// CGRequestScreenCaptureAccess once per launch. Never nags twice.
    package func requestAccessIfNeverAsked() {
        guard !requestFired else { return }
        requestFired = true
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
    }
}

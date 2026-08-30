//
//  WindowTileModel.swift
//  MaryRuntime
//
//  WHAT: Minimap eligibility / grouping / refresh as pure functions.
//  IN:   WindowCaptureService maps SCWindow → WindowInfo, then asks these rules
//  PIN:  Zero ScreenCaptureKit imports — unit-test without TCC.
//

import CoreGraphics
import Foundation

/// One enumerated window, decoupled from SCWindow so the filtering/grouping
/// rules stay pure and testable.
package struct WindowInfo: Equatable, Sendable {
    package let id: CGWindowID
    package let pid: pid_t
    package let bundleID: String?
    package let appName: String
    package let title: String?
    package let frame: CGRect
    /// SCWindow.windowLayer — 0 is a normal document window; everything else
    /// is menu bar / Dock / overlay furniture.
    package let layer: Int
    /// ≈ "on the active Space" (documented approximation — SCK reports
    /// off-Space and hidden windows as not on screen).
    let isOnScreen: Bool
    /// SCWindow.isActive — husk detector. offScreen+active is a live off-Space window.
    package var isActive: Bool = false

    package init(
        id: CGWindowID, pid: pid_t, bundleID: String?, appName: String,
        title: String?, frame: CGRect, layer: Int, isOnScreen: Bool,
        isActive: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.isActive = isActive
    }
}

/// Last photograph outcome — throw vs blank vs captured. Ghost tiles were blank success.
package enum WindowCaptureState: Equatable, Sendable {
    /// Not photographed yet this session (or degraded mode — no pixels at all).
    case never
    /// Real pixels.
    case captured
    /// Capture succeeded with a featureless surface. transparent = never drawn.
    case blank(transparent: Bool)
    /// Capture threw. The reason is kept, not swallowed.
    case failed(String)

    package var label: String {
        switch self {
        case .never: return "not captured yet"
        case .captured: return "captured"
        case .blank(let transparent):
            return transparent
                ? "captured, nothing drawn (transparent — no backing store)"
                : "captured, nothing drawn (flat fill)"
        case .failed(let reason): return "capture failed — \(reason)"
        }
    }
}

/// One rendered minimap tile: identity + the latest thumbnail, if any.
package struct WindowTile: Identifiable, Sendable {
    package let id: CGWindowID
    package let bundleID: String?
    package let pid: pid_t
    package let appName: String
    /// Raw title. Nil stays nil — never coalesce to the app name in the inspector.
    package let title: String?
    package let frame: CGRect
    package let isOnActiveSpace: Bool
    /// See WindowInfo.isActive — off-Space AND active is Stage Manager, not a
    /// husk.
    package var isActive: Bool = false
    /// SCWindow.windowLayer, carried through so the inspector can show it.
    /// Eligibility already admits only layer 0, so a non-zero here would mean
    /// the rules changed under us — worth being able to see.
    package var layer: Int = 0
    /// Nil until first capture, or degraded/failed/blank — view falls back to a card.
    package var thumbnail: CGImage?
    package var capturedAt: Date?
    package var captureState: WindowCaptureState = .never

    package init(
        id: CGWindowID, bundleID: String?, pid: pid_t, appName: String,
        title: String?, frame: CGRect, isOnActiveSpace: Bool,
        isActive: Bool = false, layer: Int = 0,
        thumbnail: CGImage? = nil, capturedAt: Date? = nil,
        captureState: WindowCaptureState = .never
    ) {
        self.id = id
        self.bundleID = bundleID
        self.pid = pid
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isOnActiveSpace = isOnActiveSpace
        self.isActive = isActive
        self.layer = layer
        self.thumbnail = thumbnail
        self.capturedAt = capturedAt
        self.captureState = captureState
    }
}

/// Is this capture real pixels or an empty surface? Pure, CoreGraphics-only,
/// so it pins without TCC or ScreenCaptureKit.
package enum WindowCaptureProbe {
    /// 16×16 sample grid. Conservative: false blank would throw away a real thumbnail.
    static let sampleEdge = 16

    package static func classify(_ image: CGImage) -> WindowCaptureState {
        guard image.width > 0, image.height > 0 else { return .blank(transparent: true) }
        let edge = sampleEdge
        let byteCount = edge * edge * 4
        let data = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 4)
        defer { data.deallocate() }
        data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        guard let context = CGContext(
            data: data, width: edge, height: edge, bitsPerComponent: 8,
            bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            // Can't sample → never accuse. An unprovable blank is a captured.
            return .captured
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))

        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for index in stride(from: 4, to: byteCount, by: 4) {
            if pixels[index] != pixels[0] || pixels[index + 1] != pixels[1]
                || pixels[index + 2] != pixels[2] || pixels[index + 3] != pixels[3] {
                return .captured
            }
        }
        return .blank(transparent: pixels[3] == 0)
    }
}

/// Tiles grouped per app — the minimap's section unit.
package struct AppTileGroup: Identifiable, Sendable {
    /// bundleID, else "pid:\(pid)" — stable across sweeps for SwiftUI.
    package let id: String
    package let bundleID: String?
    package let appName: String
    package let pid: pid_t
    package var windows: [WindowTile]
    /// Windows beyond the caps, shown as "+N more" — never silently dropped.
    package var overflowCount: Int

    package init(
        id: String, bundleID: String?, appName: String, pid: pid_t,
        windows: [WindowTile], overflowCount: Int
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.pid = pid
        self.windows = windows
        self.overflowCount = overflowCount
    }
}

package enum DegradedReason: Equatable, Sendable {
    case screenRecordingDenied
    case enumerationFailed(String)
}

package enum MinimapMode: Equatable, Sendable {
    case live
    case degraded(DegradedReason)
}

package struct MinimapModel: Sendable {
    package var mode: MinimapMode
    /// Degraded mode: one thumbnail-less tile per app (the icon-card roster).
    package var groups: [AppTileGroup]
    var sweptAt: Date

    package init(mode: MinimapMode, groups: [AppTileGroup], sweptAt: Date) {
        self.mode = mode
        self.groups = groups
        self.sweptAt = sweptAt
    }
}

/// Eyes-view filter bar. Token + predicate + cap live here so bar and capture agree.
package enum EyesFilter: Equatable, Sendable {
    /// Every enumerated app — the pane's original behaviour.
    case all
    /// Watched apps first (Xcode / Scrivener / Pages) — what she can see now.
    case eyes
    /// One app, keyed by AppTileGroup.id.
    case app(String)

    /// `@` appears in neither a CFBundleIdentifier (alphanumerics, hyphen,
    /// period) nor the "pid:N" / "bundleID#pid" fallbacks, so the sentinel
    /// can never collide with a real group id.
    package static let eyesToken = "@eyes"

    package init(token: String?) {
        guard let token else { self = .all; return }
        self = token == Self.eyesToken ? .eyes : .app(token)
    }

    /// nil IS `.all` — an absent (or decode-failed) token opens the pane on
    /// the whole desktop, which is what the pane did before the bar existed.
    package var token: String? {
        switch self {
        case .all: return nil
        case .eyes: return Self.eyesToken
        case .app(let id): return id
        }
    }

    /// The groups the pane renders. The SWEEP is never narrowed by this —
    /// `model.groups` is what populates the bar's own tabs, so hiding an app
    /// from the view must not hide it from the enumeration.
    package func visibleGroups(
        _ groups: [AppTileGroup], watchedBundleIDs: [String], watchedBundlePrefixes: [String]
    ) -> [AppTileGroup] {
        switch self {
        case .all:
            return groups
        case .eyes:
            // The SAME watched predicate the ordering uses (Scrivener's
            // build family included) — never a parallel bundle-id list.
            return groups.filter {
                WindowTileBuilder.watchedIndex(
                    of: $0.bundleID, in: watchedBundleIDs,
                    watchedBundlePrefixes: watchedBundlePrefixes) != nil
            }
        case .app(let id):
            return groups.filter { $0.id == id }
        }
    }

    /// Whose per-app cap lifts. `.all` / `.eyes` keep caps (multi-app views).
    package var uncappedGroupID: String? {
        if case .app(let id) = self { return id }
        return nil
    }

    /// Fall back to `.all` when the filtered app leaves the sweep. Empty sweep is not a quit.
    package func resolved(in groups: [AppTileGroup]) -> EyesFilter {
        guard case .app(let id) = self, !groups.isEmpty else { return self }
        return groups.contains { $0.id == id } ? self : .all
    }

    /// Screenshot budget groups. nil = every group. `.filtered` concentrates on screen.
    package func captureGroupIDs(
        scope: CaptureScope, groups: [AppTileGroup],
        watchedBundleIDs: [String], watchedBundlePrefixes: [String]
    ) -> Set<String>? {
        guard scope == .filtered, self != .all else { return nil }
        return Set(
            visibleGroups(
                groups, watchedBundleIDs: watchedBundleIDs,
                watchedBundlePrefixes: watchedBundlePrefixes
            ).map(\.id))
    }
}

/// The capture-scope toggle: what the 6-screenshots-per-tick budget buys.
/// Stored beside the filter as a raw string, same Codable tolerance.
package enum CaptureScope: String, Equatable, Sendable {
    /// Every enumerated window stays warm — a tab switch shows current
    /// pixels immediately, at the cost of spreading the budget thin.
    case all
    /// Only the filtered tab's windows — a Pages tile refreshes several times
    /// faster, but the tabs you aren't looking at go stale.
    case filtered

    package init(token: String?) {
        self = token.flatMap(CaptureScope.init(rawValue:)) ?? .all
    }
}

/// The minimap's eligibility/grouping/refresh rules — pure, test-pinned.
package enum WindowTileBuilder {
    /// Palette/tooltip floor: anything smaller isn't a working window.
    static let minWindowSize = CGSize(width: 180, height: 120)
    static let maxPerApp = 4
    package static let maxTotal = 24
    /// Pixel cap for thumbnails — crisp at ~190 pt tile width on Retina,
    /// ~370 KB each, ~15 MB ceiling on a 40-window desktop.
    static let thumbnailLongestEdge: CGFloat = 384
    /// Sequential screenshots per 1 s sweep — flat WindowServer pressure.
    static let captureBudgetPerTick = 6

    /// Skip Mary (PID beats bundle-id), non-normal layers, palettes. Keep off-Space.
    package static func eligible(_ windows: [WindowInfo], ownPID: pid_t) -> [WindowInfo] {
        windows.filter { window in
            window.pid != ownPID
                && window.layer == 0
                && window.frame.width >= minWindowSize.width
                && window.frame.height >= minWindowSize.height
        }
    }

    /// Group by bundleID (pid fallback). Watched first, then frontmost, then alpha.
    /// uncappedGroupID sheds maxPerApp and spends the total budget first.
    package static func groups(
        _ windows: [WindowInfo],
        frontmostBundleID: String?,
        watchedBundleIDs: [String],
        watchedBundlePrefixes: [String],
        uncappedGroupID: String? = nil
    ) -> [AppTileGroup] {
        // Bucket in enumeration order (SCK returns roughly front-to-back,
        // so a group's first windows are its most relevant ones).
        var order: [String] = []
        var buckets: [String: [WindowInfo]] = [:]
        for window in windows {
            let key = window.bundleID ?? "pid:\(window.pid)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(window)
        }

        var groups: [AppTileGroup] = order.compactMap { key in
            guard let members = buckets[key], let first = members.first else { return nil }
            let shown = Array(members.prefix(key == uncappedGroupID ? members.count : maxPerApp))
            return AppTileGroup(
                id: key,
                bundleID: first.bundleID,
                appName: first.appName,
                pid: first.pid,
                windows: shown.map { tile(from: $0) },
                overflowCount: members.count - shown.count)
        }

        groups.sort {
            rank(bundleID: $0.bundleID, appName: $0.appName, groupID: $0.id,
                 frontmostBundleID: frontmostBundleID,
                 watchedBundleIDs: watchedBundleIDs, watchedBundlePrefixes: watchedBundlePrefixes)
                < rank(bundleID: $1.bundleID, appName: $1.appName, groupID: $1.id,
                       frontmostBundleID: frontmostBundleID,
                       watchedBundleIDs: watchedBundleIDs, watchedBundlePrefixes: watchedBundlePrefixes)
        }

        // Total cap: later groups overflow. Uncapped group served first; display order unchanged.
        var budget = maxTotal
        var spendOrder = Array(groups.indices)
        if let uncappedGroupID,
           let hit = groups.firstIndex(where: { $0.id == uncappedGroupID }) {
            spendOrder = [hit] + spendOrder.filter { $0 != hit }
        }
        for index in spendOrder {
            let shown = groups[index].windows.count
            let allowed = min(shown, max(0, budget))
            if allowed < shown {
                groups[index].overflowCount += shown - allowed
                groups[index].windows = Array(groups[index].windows.prefix(allowed))
            }
            budget -= allowed
        }
        return groups
    }

    /// Capture candidates. Narrow here, never on eligible — sweep still feeds the tab bar.
    package static func captureCandidates(
        _ groups: [AppTileGroup], scopedTo groupIDs: Set<String>?
    ) -> [CGWindowID] {
        groups
            .filter { groupIDs?.contains($0.id) ?? true }
            .flatMap { $0.windows.map(\.id) }
    }

    /// Tab budget. Selected tab always survives the cut. Groups arrive watched-first.
    package static let maxFilterTabs = 12

    package static func filterTabs(
        _ groups: [AppTileGroup], selected: String?, limit: Int = maxFilterTabs
    ) -> (tabs: [AppTileGroup], hidden: Int) {
        guard limit > 0 else { return ([], groups.count) }
        guard groups.count > limit else { return (groups, 0) }
        var tabs = Array(groups.prefix(limit))
        if let selected, !tabs.contains(where: { $0.id == selected }),
           let kept = groups.first(where: { $0.id == selected }) {
            tabs[tabs.count - 1] = kept
        }
        return (tabs, groups.count - tabs.count)
    }

    /// Stagger scheduler: which windows to re-thumbnail this tick.
    /// Visible-in-scroll first; within each class never-captured ids outrank
    /// stale ones, then stalest-first; hard budget.
    package static func refreshBatch(
        candidates: [CGWindowID],
        visible: Set<CGWindowID>,
        lastCaptured: [CGWindowID: Date],
        budget: Int
    ) -> [CGWindowID] {
        guard budget > 0 else { return [] }
        let ordered = candidates.sorted { a, b in
            let aVisible = visible.contains(a)
            let bVisible = visible.contains(b)
            if aVisible != bVisible { return aVisible }
            switch (lastCaptured[a], lastCaptured[b]) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (.some(atA), .some(atB)) where atA != atB: return atA < atB
            default: return a < b
            }
        }
        return Array(ordered.prefix(budget))
    }

    /// Aspect-preserving pixel size for SCStreamConfiguration, capped at
    /// thumbnailLongestEdge (never upscaled past the window's own points),
    /// floor 1×1 for degenerate frames.
    package static func thumbnailPixelSize(for frame: CGRect) -> (width: Int, height: Int) {
        let width = frame.width
        let height = frame.height
        guard width > 0, height > 0 else { return (1, 1) }
        let longest = max(width, height)
        let scale = longest > thumbnailLongestEdge ? thumbnailLongestEdge / longest : 1
        return (
            max(1, Int((width * scale).rounded())),
            max(1, Int((height * scale).rounded()))
        )
    }

    // MARK: - Shared ordering

    /// The single group comparator, shared with DegradedRoster so both modes
    /// read the same way: watched tier (in watchedBundleIDs order), then the
    /// frontmost app, then alphabetical; group id breaks the final tie.
    static func rank(
        bundleID: String?,
        appName: String,
        groupID: String,
        frontmostBundleID: String?,
        watchedBundleIDs: [String],
        watchedBundlePrefixes: [String]
    ) -> (Int, Int, String, String) {
        if let index = watchedIndex(
            of: bundleID, in: watchedBundleIDs, watchedBundlePrefixes: watchedBundlePrefixes) {
            return (0, index, appName.lowercased(), groupID)
        }
        if let bundleID, bundleID == frontmostBundleID {
            return (1, 0, appName.lowercased(), groupID)
        }
        return (2, 0, appName.lowercased(), groupID)
    }

    /// Exact-id match, except roster prefix families (e.g. Scrivener builds).
    static func watchedIndex(
        of bundleID: String?, in watchedBundleIDs: [String], watchedBundlePrefixes: [String]
    ) -> Int? {
        guard let bundleID else { return nil }
        return watchedBundleIDs.firstIndex { watched in
            if watched == bundleID { return true }
            return watchedBundlePrefixes.contains { prefix in
                !prefix.isEmpty && watched.hasPrefix(prefix) && bundleID.hasPrefix(prefix)
            }
        }
    }

    private static func tile(from window: WindowInfo) -> WindowTile {
        WindowTile(
            id: window.id,
            bundleID: window.bundleID,
            pid: window.pid,
            appName: window.appName,
            title: window.title,
            frame: window.frame,
            isOnActiveSpace: window.isOnScreen,
            isActive: window.isActive,
            layer: window.layer,
            thumbnail: nil,
            capturedAt: nil)
    }
}

/// Degraded-mode roster: icon/name cards from NSWorkspace, zero TCC — one
/// thumbnail-less tile per regular app, same ordering as the live grid so
/// granting Screen Recording changes the pixels, not the layout.
package enum DegradedRoster {
    package struct AppInfo: Equatable, Sendable {
        package let bundleID: String?
        package let pid: pid_t
        package let appName: String
        /// NSApplication.ActivationPolicy.regular — Dock-visible apps only.
        let isRegular: Bool

        package init(bundleID: String?, pid: pid_t, appName: String, isRegular: Bool) {
            self.bundleID = bundleID
            self.pid = pid
            self.appName = appName
            self.isRegular = isRegular
        }
    }

    package static func groups(
        from apps: [AppInfo],
        frontmostBundleID: String?,
        watchedBundleIDs: [String],
        watchedBundlePrefixes: [String]
    ) -> [AppTileGroup] {
        var groups: [AppTileGroup] = apps.filter(\.isRegular).map { app in
            // PID-qualify ForEach ids — two instances share a bundle id. Join still uses bundleID.
            let id = app.bundleID.map { "\($0)#\(app.pid)" } ?? "pid:\(app.pid)"
            let tile = WindowTile(
                // Synthetic id — degraded mode has no CGWindowIDs at all, so
                // the pid is the only stable per-app handle.
                id: CGWindowID(bitPattern: app.pid),
                bundleID: app.bundleID,
                pid: app.pid,
                appName: app.appName,
                title: nil,
                frame: .zero,
                // Spaces are invisible without Screen Recording — claim the
                // active Space so no off-Space badge lies.
                isOnActiveSpace: true,
                // Degraded mode enumerates apps, not windows — activity/layer unknowable, not false.
                isActive: false,
                layer: 0,
                thumbnail: nil,
                capturedAt: nil,
                captureState: .never)
            return AppTileGroup(
                id: id, bundleID: app.bundleID, appName: app.appName,
                pid: app.pid, windows: [tile], overflowCount: 0)
        }
        groups.sort {
            WindowTileBuilder.rank(
                bundleID: $0.bundleID, appName: $0.appName, groupID: $0.id,
                frontmostBundleID: frontmostBundleID,
                watchedBundleIDs: watchedBundleIDs, watchedBundlePrefixes: watchedBundlePrefixes)
                < WindowTileBuilder.rank(
                    bundleID: $1.bundleID, appName: $1.appName, groupID: $1.id,
                    frontmostBundleID: frontmostBundleID,
                    watchedBundleIDs: watchedBundleIDs, watchedBundlePrefixes: watchedBundlePrefixes)
        }
        return groups
    }
}

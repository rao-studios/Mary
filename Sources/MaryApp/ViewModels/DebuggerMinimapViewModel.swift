//
//  DebuggerMinimapViewModel.swift
//  Mary
//
//  WHAT: Capture-actor → SwiftUI while pane open (1 s poll). Pixels + app roster.
//  OUT:  DebuggerPaneView. Perception captions live on PerceptionSnapshotViewModel.
//  PIN:  Never Granite @Store.
//

import AppKit
import MaryBrain
import SwiftUI
import MaryRuntime

@MainActor
final class DebuggerMinimapViewModel: ObservableObject {

    @Published private(set) var model = MinimapModel(
        mode: .live, groups: [], sweptAt: .distantPast)
    @Published private(set) var screenRecordingGranted = false

    private var pollTask: Task<Void, Never>?
    private var visibleTiles: Set<CGWindowID> = []
    private var iconCache: [pid_t: NSImage] = [:]
    private var ticking = false

    /// Poll inputs, not display state. Center is the single writer the pane renders from.
    private var filter: EyesFilter = .all
    private var captureScope: CaptureScope = .all

    /// Watched-first eyes. Derived from PerceptionWorld.watched (the live-observer set).
    static var watchedBundleIDs: [String] {
        PerceptionWorld.watched.map(\.representativeBundleID)
    }

    /// Declared process families from the roster (Setapp builds tile with their app).
    static var watchedBundlePrefixes: [String] {
        AmbientApplicationIndexProvider.current.all
            .filter(\.hasEyes)
            .compactMap(\.bundleIdentifierPrefix)
            .filter { !$0.isEmpty }
    }

    func start() {
        guard pollTask == nil else { return }
        // The first-open ceremony fires once per app launch, inside the
        // actor's own flag — reopening the pane never nags again.
        Task { await MaryRuntime.captureService.requestAccessIfNeverAsked() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The filter bar's selection, pushed down from Debugger.Center. Sweeps
    /// immediately rather than waiting out the 1 s tick — a tab click that
    /// takes a second to lift the cap reads as a dropped click.
    func setFilter(_ filter: EyesFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        refreshNow()
    }

    func setCaptureScope(_ scope: CaptureScope) {
        guard captureScope != scope else { return }
        captureScope = scope
        refreshNow()
    }

    private func refreshNow() {
        guard pollTask != nil else { return }   // pane closed: no WindowServer traffic
        Task { [weak self] in await self?.tick() }
    }

    /// Scroll visibility → stagger priority: visible tiles refresh every
    /// 1–2 s while off-screen ones rotate through the budget.
    func tileAppeared(_ id: CGWindowID) {
        visibleTiles.insert(id)
    }

    func tileDisappeared(_ id: CGWindowID) {
        visibleTiles.remove(id)
    }

    /// Memoized app icon for the degraded/icon-card tiles. NSImage is main-
    /// actor machinery — the capture actor never touches it.
    func icon(forPID pid: pid_t) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else {
            return nil
        }
        iconCache[pid] = icon
        return icon
    }

    // MARK: - The 1 Hz tick

    private func tick() async {
        // One sweep at a time so a later tick cannot republish a staler model.
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }

        screenRecordingGranted = PermissionsCenter.status(of: .screenRecording) == .granted
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        var swept: MinimapModel
        if screenRecordingGranted {
            swept = await MaryRuntime.captureService.poll(
                visibleWindowIDs: visibleTiles,
                frontmostBundleID: frontmost,
                watchedBundleIDs: Self.watchedBundleIDs,
                watchedBundlePrefixes: Self.watchedBundlePrefixes,
                uncappedGroupID: filter.uncappedGroupID,
                // Scope from previous groups; new apps wait one tick.
                captureGroupIDs: filter.captureGroupIDs(
                    scope: captureScope, groups: model.groups,
                    watchedBundleIDs: Self.watchedBundleIDs,
                    watchedBundlePrefixes: Self.watchedBundlePrefixes))
        } else {
            swept = MinimapModel(
                mode: .degraded(.screenRecordingDenied), groups: [], sweptAt: Date())
        }
        // Any degraded sweep (denied, or enumeration failed mid-session)
        // falls back to the icon-card roster so the pane never goes empty.
        if case .degraded = swept.mode {
            swept.groups = DegradedRoster.groups(
                from: rosterApps(),
                frontmostBundleID: frontmost,
                watchedBundleIDs: Self.watchedBundleIDs,
                watchedBundlePrefixes: Self.watchedBundlePrefixes)
        }
        model = swept
        // Perception captions live in PerceptionSnapshotViewModel's cards
        // now (the single source the inspector shares) — this model is
        // pixels + roster only.
    }

    /// The zero-TCC roster: Dock-visible apps minus Mary itself (PID beats
    /// bundle-id, same as the live eligibility rule).
    private func rosterApps() -> [DegradedRoster.AppInfo] {
        let ownPID = getpid()
        return NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID }
            .map { app in
                DegradedRoster.AppInfo(
                    bundleID: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? app.bundleIdentifier ?? "unknown",
                    isRegular: app.activationPolicy == .regular)
            }
    }
}

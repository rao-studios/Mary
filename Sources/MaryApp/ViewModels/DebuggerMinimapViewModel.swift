//
//  DebuggerMinimapViewModel.swift
//  Mary
//
//  Bridges the capture actor to SwiftUI while the pane is open — 1 s poll,
//  AbilityExecutionLogViewModel's shape. NEVER Granite @Store: the 200 ms debounce
//  would blur a realtime minimap (the standing doctrine — Debugger.Center
//  holds only click-scoped state). Perception captions are NOT built here:
//  PerceptionSnapshotViewModel's cards are the single source for what the
//  watchers see; this model owns pixels and the app roster only.
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

    /// POLL INPUTS, not state. Debugger.Center is the single writer and the
    /// single source the pane RENDERS from; these are the pushed copies the
    /// 1 Hz tick needs to parameterise the actor call, written only by
    /// `setFilter`/`setCaptureScope` and never read back for display. Holding
    /// the selection in both places as *state* is the duplication the
    /// pin-badge bug taught (see DebuggerPaneView.isPinned).
    private var filter: EyesFilter = .all
    private var captureScope: CaptureScope = .all

    /// Mary's actual eyes, in watched-first display order. DERIVED, not
    /// re-listed: `PerceptionWorld.watched` excludes recognizable unavailable
    /// cards such as Keynote and bridges to `AmbientWorld.hasEyes` — the one
    /// spelling of the live-observer set. A hand-typed copy here was the
    /// fifth spelling of the same three app names, and the header below
    /// records what that costs: a narrower predicate than focus's sorted a
    /// live-tracked build out of the watched group. Internal (not private)
    /// because the pane's "Eyes" tab must ask THIS list what counts as
    /// watched.
    static var watchedBundleIDs: [String] {
        PerceptionWorld.watched.map(\.representativeBundleID)
    }

    /// THE DECLARED PROCESS FAMILIES of the watched applications — what a
    /// single hardcoded Scrivener prefix used to be. Read from the roster, so
    /// a taught application's Setapp build tiles into its own slot instead of
    /// appearing as an app Mary has never heard of.
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
        // A tab click sweeps immediately, so two ticks can overlap while the
        // actor is mid-screenshot; the later one would republish a staler
        // model over the fresher one. One sweep at a time — a skipped tick
        // costs a second, a reordered one costs the user's trust.
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
                // Computed off the PREVIOUS sweep's groups: the actor needs
                // the scope before it enumerates, and group ids are stable
                // across sweeps (bundle id, else pid) — a brand-new app is
                // simply out of scope for the one tick it takes to appear.
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

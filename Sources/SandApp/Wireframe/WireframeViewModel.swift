//
//  WireframeViewModel.swift
//  Sand
//
//  WHAT: The stage's state — one poller for the chosen target, its latest
//        snapshot, the zoom stack, the detail decoration, the ambient artifact.
//  IN:   AXSnapshotPoller
//  OUT:  WireframeStageView / WireframeHUD / AmbientInspectorView
//  PIN:  A THIN CONSUMER. Every decidable rule lives across the seam in
//        MaryComputerUse — AXHitTest resolves a tap, AXDesktopPlane converts
//        coordinates, AXAmbientPresentation writes every string — because Sand
//        has no test target and code that lives here cannot be pinned.
//        Ported from Bonnie's Clyde WireframeViewModel; the streamer it held
//        became AXSnapshotPoller (Live/), which is the only real difference.
//
import AppKit
import Foundation
import MaryComputerUse

/// One step of a click-to-zoom drill-down — "the app" down to "this one
/// button", each click narrowing the stage to what was clicked. Sand-local:
/// navigation state over a published snapshot, not something the engine needs
/// to know exists.
struct ZoomFrame: Identifiable, Equatable {
    let id: AXNodeID
    let label: String
    /// Re-resolved by id on every fresh snapshot (`AXHitTest.frame(of:in:)`)
    /// so a zoomed-in view tracks a moving or resizing target instead of
    /// freezing on the rect it had at click time. Left unchanged when the id
    /// is gone — see `refreshZoomFrames`.
    var frame: CGRect
}

@MainActor
final class WireframeViewModel: ObservableObject {
    @Published private(set) var latest: AXAppSnapshot?
    @Published private(set) var stats = AXSnapshotPoller.Stats()
    @Published private(set) var plane: AXDesktopPlane = .empty
    @Published private(set) var targetName: String = ""
    @Published private(set) var targetPID: pid_t?
    @Published private(set) var zoomStack: [ZoomFrame] = []
    /// The zoomed target's DETAIL decoration — text content, control values,
    /// styled runs — or nil while un-zoomed, in flight, or refused. See
    /// `AXDetailReader`: this is what lets the stage draw a reconstruction of
    /// an element instead of its outline.
    @Published private(set) var focusDetail: AXSubtreeDetail?
    /// THE AMBIENT ARTIFACT for the watched target — what this walk would
    /// contribute to Mary's tier-0 ambient context, inspectable here. Derived
    /// purely from `latest` (no new lane, no extra IPC), and only while
    /// something is showing it.
    @Published private(set) var ambient: AXAmbientContext?
    /// The roster row selected in the ambient inspector, if any. An id, not a
    /// stored element — `ambient` is replaced wholesale on every publish, so
    /// the row is RESOLVED by id at render time, never held as a stale value.
    @Published private(set) var selectedElementID: AXNodeID?

    /// The selected row's current element, or nil once it has scrolled out of
    /// the published roster. Computed, never cached.
    var selectedElement: AXScreenElement? {
        guard let selectedElementID else { return nil }
        return ambient?.elements.first { $0.id == selectedElementID }
    }

    func selectElement(_ id: AXNodeID?) {
        selectedElementID = (selectedElementID == id) ? nil : id
    }

    /// Whether anything is displaying the ambient artifact. Derivation is
    /// cheap but not free (it flattens the front window's roster on every
    /// publish), so it runs only when a reader exists.
    var ambientVisible = false {
        didSet {
            guard ambientVisible != oldValue else { return }
            if ambientVisible {
                refreshAmbient()
            } else {
                ambient = nil
            }
        }
    }

    private var poller: AXSnapshotPoller?
    private var streamTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var lastDetailRequestedAt: ContinuousClock.Instant?
    private let detailClock = ContinuousClock()
    /// Floor between two detail reads while a zoom is held. Detail is
    /// parameterized IPC — far dearer than the walk — so it rides a slow
    /// cadence of its own rather than the publish rate; the target's text does
    /// not change four times a second, and a read that outlived its usefulness
    /// is cancelled by the next one anyway.
    private static let detailRefreshFloor: Duration = .milliseconds(250)
    private var screenObserver: NSObjectProtocol?
    /// Held for as long as a poll is live. Sand is a MONITORING app: the user
    /// is necessarily looking at the target, not at Sand, so App Nap and timer
    /// coalescing would throttle exactly the run loop the wireframe depends on
    /// — precisely when it must keep up.
    private var activityAssertion: NSObjectProtocol?

    init() {
        recomputePlane()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recomputePlane() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// The current viewport: the whole desktop until a click zooms in, after
    /// which it is the last-clicked element's (or window's) frame —
    /// `AXDesktopPlane.focused(on:)` turns that rect into a plane everything
    /// else draws and measures against exactly as it would the real desktop.
    var focusedPlane: AXDesktopPlane {
        guard let focus = zoomStack.last?.frame else { return plane }
        return plane.focused(on: focus)
    }

    /// How much bigger the current viewport draws things than the full desktop
    /// would — 1 at the top level, growing as `zoomStack` narrows the focus.
    /// `WireframeRenderer` rides this to keep `.container`/`.text` legible once
    /// zoomed in rather than pinned at the hairline a whole-desktop view calls
    /// for.
    var magnification: CGFloat {
        guard let focus = zoomStack.last?.frame, focus.width > 0, focus.height > 0
        else { return 1 }
        let baselineArea = plane.desktopBounds.width * plane.desktopBounds.height
        let focusArea = focus.width * focus.height
        guard baselineArea > 0, focusArea > 0 else { return 1 }
        return (baselineArea / focusArea).squareRoot()
    }

    func start(pid: pid_t, bundleID: String?, name: String) {
        stop()
        targetName = name
        targetPID = pid
        zoomStack = []
        activityAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Live AX wireframe polling")
        let poller = AXSnapshotPoller(pid: pid, bundleID: bundleID)
        self.poller = poller
        streamTask = Task {
            for await snapshot in await poller.snapshots() {
                self.latest = snapshot
                self.refreshZoomFrames(in: snapshot)
                self.requestDetailIfStale()
                self.refreshAmbient()
            }
        }
        statsTask = Task {
            while !Task.isCancelled {
                self.stats = await poller.currentStats()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The bench raises the cadence while an ability runs, so a recipe's whole
    /// visible effect is not missed between two idle ticks.
    func setCadence(_ cadence: AXSnapshotPoller.Cadence) {
        guard let poller else { return }
        Task { await poller.setCadence(cadence) }
    }

    /// Re-derive the ambient artifact, and republish ONLY when the screen
    /// actually changed: `AXAmbientContext.==` ignores capture timing, so a
    /// window being dragged re-derives cheaply but never invalidates the
    /// panel's list until something real moves.
    private func refreshAmbient() {
        guard ambientVisible, let latest else { return }
        let derived = AXAmbientContext(snapshot: latest)
        guard derived != ambient else { return }
        ambient = derived
    }

    func stop() {
        streamTask?.cancel()
        statsTask?.cancel()
        detailTask?.cancel()
        streamTask = nil
        statsTask = nil
        detailTask = nil
        focusDetail = nil
        ambient = nil
        selectedElementID = nil
        lastDetailRequestedAt = nil
        if let activityAssertion {
            ProcessInfo.processInfo.endActivity(activityAssertion)
        }
        activityAssertion = nil
        let poller = self.poller
        self.poller = nil
        latest = nil
        targetPID = nil
        zoomStack = []
        Task { await poller?.stop() }
    }

    // MARK: - Click-to-zoom

    /// A tap on the stage, in VIEW points against the size the Canvas drew at
    /// — converted through `focusedPlane` (the viewport the user was actually
    /// looking at, not always the raw desktop) into AX space, then resolved to
    /// the smallest thing there.
    func handleTap(at viewPoint: CGPoint, size: CGSize) {
        guard let snapshot = latest else { return }
        let axPoint = focusedPlane.axPoint(for: viewPoint, in: size)
        guard let target = AXHitTest.target(in: snapshot, at: axPoint) else { return }
        // Tapping the thing already fully zoomed-in on would push a redundant,
        // identical frame.
        guard zoomStack.last?.id != target.id else { return }
        // `AXHitTest.target` searches the whole snapshot, not just the
        // currently-focused subtree — a tap can resolve to an outer container
        // (an ancestor, or a window) rather than something deeper.
        // `trailDepth` pops every trailing level that container already
        // contains, so tapping "up" navigates back to that level instead of
        // appending a backwards breadcrumb entry.
        let keep = AXHitTest.trailDepth(zoomStack.map(\.frame), navigatingTo: target.frame)
        zoomStack = Array(zoomStack.prefix(keep))
            + [ZoomFrame(id: target.id, label: target.label, frame: target.frame)]
        focusChanged()
    }

    /// Breadcrumb navigation. `index == -1` clears the stack entirely (back to
    /// the whole desktop); any other index keeps that many entries, so
    /// clicking a crumb returns to exactly the zoom level it represents.
    func zoomOut(to index: Int) {
        guard index >= 0 else { zoomStack = []; focusChanged(); return }
        guard index < zoomStack.count - 1 else { return }
        zoomStack = Array(zoomStack.prefix(index + 1))
        focusChanged()
    }

    /// Zoom straight to a node the bench pointed at — the acted element of a
    /// run, say. Same state a tap would have produced, so the breadcrumb and
    /// the detail lane behave identically afterwards.
    func zoom(to id: AXNodeID, label: String) {
        guard let snapshot = latest, let frame = AXHitTest.frame(of: id, in: snapshot)
        else { return }
        guard zoomStack.last?.id != id else { return }
        let keep = AXHitTest.trailDepth(zoomStack.map(\.frame), navigatingTo: frame)
        zoomStack = Array(zoomStack.prefix(keep))
            + [ZoomFrame(id: id, label: label, frame: frame)]
        focusChanged()
    }

    // MARK: - The detail lane

    /// A NEW zoom target. The old decoration is dropped immediately — drawing
    /// one element's text inside another's frame is the one failure worse than
    /// drawing no text at all — and a fresh read starts without waiting for the
    /// throttle, since this is the moment the user is actually looking.
    private func focusChanged() {
        focusDetail = nil
        lastDetailRequestedAt = nil
        requestDetailIfStale()
    }

    /// Re-read the focused subtree's detail, no more often than
    /// `detailRefreshFloor`. Un-zoomed, there is nothing to decorate and
    /// nothing is spent.
    private func requestDetailIfStale() {
        guard let target = zoomStack.last?.id, let poller else { return }
        let now = detailClock.now
        if let last = lastDetailRequestedAt, now - last < Self.detailRefreshFloor { return }
        lastDetailRequestedAt = now

        detailTask?.cancel()
        detailTask = Task { [weak self] in
            let detail = await poller.detail(for: target)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // The zoom may have moved on while the read was in flight; a
                // decoration for a target nobody is looking at any more must
                // never land on the current one.
                guard self.zoomStack.last?.id == target else { return }
                // A refused read (the id vanished, or its role changed under a
                // recycled hash) KEEPS what was last shown, the same way a
                // vanished crumb keeps its last-known frame — a momentarily
                // stale reconstruction beats a view that empties itself.
                if let detail { self.focusDetail = detail }
            }
        }
    }

    /// Re-locate every stacked frame in a fresh snapshot so a live zoom tracks
    /// its target (a moving window, a resizing pane) instead of drifting
    /// stale. An id that has vanished keeps its LAST known frame rather than
    /// popping the stack — jumping the user's view without their say-so is
    /// worse than a briefly-stale one.
    private func refreshZoomFrames(in snapshot: AXAppSnapshot) {
        guard !zoomStack.isEmpty else { return }
        zoomStack = zoomStack.map { entry in
            guard let updated = AXHitTest.frame(of: entry.id, in: snapshot) else { return entry }
            var entry = entry
            entry.frame = updated
            return entry
        }
    }

    private func recomputePlane() {
        let screens = NSScreen.screens
        guard let primary = screens.first else { plane = .empty; return }
        plane = AXDesktopPlane(
            cocoaScreenFrames: screens.map(\.frame),
            primaryScreenHeight: primary.frame.height)
    }
}

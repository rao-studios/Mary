//
//  AmbientSurfaceObserver.swift
//  MaryAdapter
//
//  THE TIER-0 WIRING: one lean poller, one AXEngine walk, two publications.
//
//  Every poll captures the frontmost application's ambient context through
//  the engine (`AXEngine.ambientContext`) and publishes it twice:
//    1. the SURFACE — `AmbientContextStore.noteSurface`, for EVERY family,
//       browsers included: the tier the store's whole doctrine now rests on,
//       and a lane nothing else writes.
//    2. the AFFORDANCE SLATE — the same walk's roster rendered by
//       `AmbientBridge.affordances(from:)` into the scope the retired
//       `AffordanceObserver` used to fill from its own separate
//       `PageElementReader.readWindowControls` walk. The browser carve-out
//       is preserved FOR THIS PUBLICATION ONLY: `BrowserContextWatcher`
//       publishes the browser place's slate from the page rather than the
//       window, and two publishers writing one scope is how two lanes start
//       disagreeing.
//
//  ONE-SHOT PER POLL, NEVER A RETARGETING STREAMER. A streamer per
//  frontmost app would install and tear down AXObserver resources — and
//  kick a ≤6s web wake — on every alt-tab; the ambient need is 10-second
//  freshness, which one bounded walk serves at the cost class the retired
//  observer already paid.
//
//  THE SURFACE IS ALWAYS RE-NOTED (a dict write with the fresh capture
//  stamp — the walk was already paid); the AFFORDANCE publication is
//  skipped when the walked truth is unchanged (timing-insensitive
//  `AXAmbientContext.==`), because that one re-vectorizes into the
//  embedding index.
//
//  ONE SLATE AT A TIME, the retired observer's rule kept verbatim: a change
//  of application retracts the previous affordance scope before the new one
//  publishes, and a nil target retracts outright — a stale affordance is a
//  confidently wrong press waiting for a phrase. Surfaces are NOT retracted
//  on switch: latest-per-family is the tier's job, and drop-at-expiry is
//  its honesty.
//

import AppKit
import ApplicationServices
import MaryAmbient
import Foundation
import os

public final class AmbientSurfaceObserver: MaryObserver, @unchecked Sendable {

    public static let shared = AmbientSurfaceObserver()

    public let id = "ambient_surface"
    public let ambientSenses: Set<AmbientSense> = [.workspace]

    /// The retired `AffordanceObserver`'s numbers, inherited with their
    /// rationale: slower than the selection watchers, faster than the
    /// browser's osascript poll; a window changing what it offers is the
    /// kind of change a person notices within a breath.
    public static let activeInterval: TimeInterval = 10
    public static let idleInterval: TimeInterval = 45

    static let log = Logger(subsystem: "nyc.rao.mary", category: "surface")

    /// The frontmost target worth reading.
    ///
    /// Public for `--probe-ambient-surface`, which drives THIS observer
    /// rather than restating its ladder — a probe that reimplemented the
    /// decision would be a second implementation to disagree with.
    public struct Target {
        public var pid: pid_t
        public var bundleID: String
        public var place: AmbientPlace
    }

    private let store: AmbientContextStore
    private let elementIndex: AmbientElementIndexStore
    private let capture: @Sendable (pid_t) -> AXAmbientContext?
    private let frontmost: @Sendable () -> (pid: pid_t, bundleID: String)?
    private let trusted: @Sendable () -> Bool

    private let taskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let runningBox = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let pendingBox = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// The affordance scope currently holding records — the one-slate rule.
    private let publishedBox =
        OSAllocatedUnfairLock<AmbientElementScope?>(initialState: nil)
    /// The last walked truth per target, for the skip-when-unchanged rule.
    private let lastContextBox =
        OSAllocatedUnfairLock<(pid: pid_t, context: AXAmbientContext)?>(initialState: nil)
    /// The lane whose surface this observer last noted — deactivate's teardown.
    private let lastPlaceBox = OSAllocatedUnfairLock<AmbientPlace?>(initialState: nil)

    public convenience init() {
        self.init(
            store: .shared,
            elementIndex: .shared,
            capture: { AXEngine.ambientContext(pid: $0) },
            frontmost: {
                guard let front = NSWorkspace.shared.frontmostApplication,
                      let bundleID = front.bundleIdentifier else { return nil }
                return (front.processIdentifier, bundleID)
            },
            trusted: { AXIsProcessTrusted() })
    }

    init(
        store: AmbientContextStore,
        elementIndex: AmbientElementIndexStore,
        capture: @escaping @Sendable (pid_t) -> AXAmbientContext?,
        frontmost: @escaping @Sendable () -> (pid: pid_t, bundleID: String)?,
        trusted: @escaping @Sendable () -> Bool
    ) {
        self.store = store
        self.elementIndex = elementIndex
        self.capture = capture
        self.frontmost = frontmost
        self.trusted = trusted
    }

    public var isActive: Bool { taskBox.withLock { $0 != nil } }

    // MARK: - Lifecycle

    public func activate() async {
        let started: Bool = taskBox.withLock { current in
            guard current == nil else { return false }
            current = Task { [weak self] in await self?.loop() }
            return true
        }
        if started { requestPoll() }
    }

    public func deactivate() async {
        taskBox.withLock { current in
            current?.cancel()
            current = nil
        }
        retractAffordances()
        let place = lastPlaceBox.withLock { place -> AmbientPlace? in
            defer { place = nil }
            return place
        }
        if let place { store.forgetSurface(place: place) }
        lastContextBox.withLock { $0 = nil }
    }

    public func refreshAmbientContext() async { requestPoll() }

    /// Nil — the retired observer's reason verbatim: the output channels are
    /// the store's surface tier and the element index, which cost no prompt
    /// bytes here; the prompt reads the surface through `heldContext`, where
    /// budget and lead order are decided.
    public func promptContribution() -> String? { nil }

    // MARK: - The loop

    private func loop() async {
        while !Task.isCancelled {
            // Sleep first, the observer family's shape: activation runs at
            // boot and on every Settings save.
            let interval = target() == nil
                ? Self.idleInterval : Self.activeInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            requestPoll()
        }
    }

    private func requestPoll() {
        let shouldStart: Bool = runningBox.withLock { running in
            if running {
                pendingBox.withLock { $0 = true }
                return false
            }
            running = true
            return true
        }
        guard shouldStart else { return }
        Task { [weak self] in
            guard let self else { return }
            self.pollOnce()
            let again: Bool = self.runningBox.withLock { running in
                running = false
                return self.pendingBox.withLock { pending in
                    defer { pending = false }
                    return pending
                }
            }
            if again, !Task.isCancelled { self.requestPoll() }
        }
    }

    // MARK: - The read

    /// The application worth reading, or nil. BROWSERS ARE INCLUDED — the
    /// engine's web sub-engine handles them, and the surface tier has no
    /// competing writer; only the AFFORDANCE publication below keeps the
    /// browser carve-out. Excluded: Mary itself, and the tracker's own
    /// system-chrome list (Spotlight, the Dock — artifacts, not reading
    /// targets).
    public func target() -> Target? {
        guard trusted() else { return nil }
        guard let front = frontmost(),
              front.bundleID != Bundle.main.bundleIdentifier,
              !WorkspaceFocusTracker.leadExcludedBundlePrefixes
                  .contains(where: front.bundleID.hasPrefix)
        else { return nil }
        return Target(
            pid: front.pid,
            bundleID: front.bundleID,
            place: AmbientPlaceResolver.applicationPlace(forBundleID: front.bundleID))
    }

    public func pollOnce(at now: Date = Date()) {
        guard let target = target() else {
            // Nothing readable in front: retract the slate (what was true of
            // the last window is not evidence about this one); surfaces are
            // left to expire on their own honesty.
            retractAffordances()
            return
        }
        guard let context = capture(target.pid) else {
            retractAffordances()
            return
        }

        // 1 — the surface, every family, every poll.
        store.noteSurface(
            AmbientBridge.surface(from: context, place: target.place), at: now)
        lastPlaceBox.withLock { $0 = target.place }

        // 2 — the affordance slate, unless the browser watcher owns it.
        guard !AmbientPlaceResolver.isBrowser(bundleID: target.bundleID) else {
            retractAffordances()
            lastContextBox.withLock { $0 = (target.pid, context) }
            return
        }
        let unchanged = lastContextBox.withLock { last -> Bool in
            defer { last = (target.pid, context) }
            return last?.pid == target.pid && last?.context == context
        }
        let scope = AmbientElementScope.affordances(in: target.place)
        let previous = publishedBox.withLock { current -> AmbientElementScope? in
            defer { current = scope }
            return current == scope ? nil : current
        }
        if let previous {
            elementIndex.noteElements([], scope: previous)
        } else if unchanged {
            // Same window, same truth, same scope — the slate already says
            // this; skip the re-vectorization.
            return
        }
        elementIndex.noteElements(
            AffordanceRule.records(
                for: AmbientBridge.affordances(from: context), scope: scope),
            scope: scope)
    }

    private func retractAffordances() {
        let previous = publishedBox.withLock { current -> AmbientElementScope? in
            defer { current = nil }
            return current
        }
        guard let previous else { return }
        elementIndex.noteElements([], scope: previous)
    }
}

/// The support bundle, `BrowserSupport`'s shape.
public enum AmbientSurfaceSupport {
    public static let shared = AmbientSurfaceSupport.self
    public static var all: [any MaryObserver] { [AmbientSurfaceObserver.shared] }
}

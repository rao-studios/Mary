//
//  AmbientSurfaceObserver.swift
//  MaryAdapter
//
//  WHAT: One poller, one AXEngine walk, two publications (surface + affordance slate).
//  IN:   AXEngine.ambientContext
//  OUT:  AmbientContextStore.noteSurface / AmbientElementIndexStore
//  PIN:  One-shot per poll, never a streamer. Surface always re-noted;
//        affordance skipped when AXAmbientContext.==. One slate at a time.
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

    /// Cadence: slower than selection watchers, faster than the browser osascript poll.
    public static let activeInterval: TimeInterval = 10
    public static let idleInterval: TimeInterval = 45

    static let log = Logger(subsystem: "nyc.rao.mary", category: "surface")

    /// Frontmost target worth reading. Public for `--probe-ambient-surface`.
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
    /// Standing-workspace inputs. Empty by default so tests never walk a live Xcode.
    private let standingClaims: @Sendable () -> [ApplicationRegistration]
    private let standingRunning: @Sendable () -> [SurfacePollTarget.Process]
    private let standingPreferred: @Sendable () -> [String]
    private let maryBundleID: String?

    private let taskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let runningBox = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let pendingBox = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Affordance scope currently holding records — one-slate rule.
    private let publishedBox =
        OSAllocatedUnfairLock<AmbientElementScope?>(initialState: nil)
    /// Last walked truth per target — skip-when-unchanged.
    private let lastContextBox =
        OSAllocatedUnfairLock<(pid: pid_t, context: AXAmbientContext)?>(initialState: nil)
    /// Lane whose surface this observer last noted — deactivate teardown.
    private let lastPlaceBox = OSAllocatedUnfairLock<AmbientPlace?>(initialState: nil)

    public convenience init() {
        self.init(
            store: .shared,
            elementIndex: .shared,
            capture: { pid in
                let bundleID = NSRunningApplication(processIdentifier: pid)?
                    .bundleIdentifier
                return AXEngine.ambientContext(
                    pid: pid,
                    declaredEditorRoles: DeclaredEditorRoles.names(bundleID: bundleID))
            },
            frontmost: {
                guard let front = NSWorkspace.shared.frontmostApplication,
                      let bundleID = front.bundleIdentifier else { return nil }
                return (front.processIdentifier, bundleID)
            },
            trusted: { AXIsProcessTrusted() },
            standingClaims: { AmbientApplicationIndexProvider.current.all },
            standingRunning: { SurfacePollTarget.runningProcesses() },
            standingPreferred: {
                [WorkspaceFocusTracker.shared.leadPlace()?.application]
                    .compactMap { $0 }
            },
            maryBundleID: Bundle.main.bundleIdentifier)
    }

    init(
        store: AmbientContextStore,
        elementIndex: AmbientElementIndexStore,
        capture: @escaping @Sendable (pid_t) -> AXAmbientContext?,
        frontmost: @escaping @Sendable () -> (pid: pid_t, bundleID: String)?,
        trusted: @escaping @Sendable () -> Bool,
        standingClaims: @escaping @Sendable () -> [ApplicationRegistration] = { [] },
        standingRunning: @escaping @Sendable () -> [SurfacePollTarget.Process] = { [] },
        standingPreferred: @escaping @Sendable () -> [String] = { [] },
        maryBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.store = store
        self.elementIndex = elementIndex
        self.capture = capture
        self.frontmost = frontmost
        self.trusted = trusted
        self.standingClaims = standingClaims
        self.standingRunning = standingRunning
        self.standingPreferred = standingPreferred
        self.maryBundleID = maryBundleID
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

    /// Nil — surface and element index cost no prompt bytes; prompt reads via heldContext.
    public func promptContribution() -> String? { nil }

    // MARK: - The loop

    private func loop() async {
        while !Task.isCancelled {
            // Sleep first — observer family: activation runs at boot and on Settings save.
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

    /// Application worth reading, or nil. Browsers included for the surface; Mary's tree never.
    public func target() -> Target? {
        guard trusted() else { return nil }
        let front = frontmost()
        if let front,
           !WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: front.bundleID, maryBundleID: maryBundleID) {
            return Target(
                pid: front.pid,
                bundleID: front.bundleID,
                place: AmbientPlaceResolver.applicationPlace(forBundleID: front.bundleID))
        }
        let running = standingRunning()
        guard let hit = SurfacePollTarget.resolve(
            frontmostBundleID: front?.bundleID,
            maryBundleID: maryBundleID,
            claims: standingClaims(),
            running: running,
            preferredApplicationIDs: standingPreferred(),
            unpreferredFallback: false),
              let process = running.first(where: { $0.pid == hit.pid }),
              process.bundleID != maryBundleID
        else { return nil }
        return Target(
            pid: hit.pid,
            bundleID: process.bundleID,
            place: AmbientPlaceResolver.applicationPlace(forBundleID: process.bundleID))
    }

    public func pollOnce(at now: Date = Date()) {
        guard let target = target() else {
            // Nothing readable: retract the slate. Surfaces expire on their own.
            retractAffordances()
            return
        }
        guard let context = capture(target.pid) else {
            retractAffordances()
            return
        }

        // 1 — surface, every family, every poll.
        store.noteSurface(
            AmbientBridge.surface(from: context, place: target.place), at: now)
        lastPlaceBox.withLock { $0 = target.place }
        stampLookTarget(from: context, target: target)

        // 2 — affordance slate, unless the browser watcher owns it.
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
            // Same window, same truth, same scope — skip re-vectorization.
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

    /// Tag the focused declared editor pane so look_at_screen has an honest bbox.
    private func stampLookTarget(from context: AXAmbientContext, target: Target) {
        let roles = DeclaredEditorRoles.names(bundleID: target.bundleID)
        guard let editor = AXElementRoster.preferredDeclaredEditor(
            in: context.elements, roles: roles)
        else { return }
        WorkspaceFocusTracker.shared.notePaneTarget(FocusPaneTarget(
            place: target.place,
            identity: AmbientBridge.identity(of: editor),
            frame: editor.frame))
    }
}

/// Support bundle, BrowserSupport's shape.
public enum AmbientSurfaceSupport {
    public static let shared = AmbientSurfaceSupport.self
    public static var all: [any MaryObserver] { [AmbientSurfaceObserver.shared] }
}

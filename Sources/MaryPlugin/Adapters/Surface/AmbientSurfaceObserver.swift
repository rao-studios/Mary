//
//  AmbientSurfaceObserver.swift
//  MaryPlugin
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
import MaryComputerUse
import os

public final class AmbientSurfaceObserver: MaryObserver, @unchecked Sendable {

    public static let shared = AmbientSurfaceObserver()

    public let id = "ambient_surface"
    public let ambientSenses: Set<AmbientSense> = [.workspace]

    /// Cadence: slower than selection watchers, faster than the browser osascript poll.
    public static let activeInterval: TimeInterval = 10
    public static let idleInterval: TimeInterval = 45

    /// HOW OFTEN THE STANDING SWEEP RUNS — the idle cadence, deliberately not a
    /// new number. The frontmost window is polled every 10s because it is what
    /// the person is looking at; a taught application BEHIND it changes slowly
    /// and is worth a walk only occasionally.
    public static let sweepInterval: TimeInterval = idleInterval

    /// HOW MANY BACKGROUND APPLICATIONS ONE SWEEP MAY WALK.
    ///
    /// PIN: BOUNDED BY THE REGISTRY AND THEN BY THIS. Only SIGHTED registrations
    /// are eligible — never a random running process — but a machine with a
    /// dozen taught applications open would still pay a dozen exhaustive AX
    /// walks in one tick, which is exactly the cost this layer is careful
    /// about. Four is two more than anyone has led recently and cheap enough to
    /// disappear inside a 45s window.
    public static let sweepLimit = 4

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
    /// When the standing sweep last ran. Its own clock, because the poll is
    /// coalesced and re-entrant and the sweep must not ride every poke.
    private let lastSweepBox = OSAllocatedUnfairLock<Date?>(initialState: nil)
    /// Places the sweep has noted, so `deactivate` can put them all back.
    private let sweptPlacesBox = OSAllocatedUnfairLock<Set<AmbientPlace>>(initialState: [])

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
        // AND EVERYTHING THE SWEEP NOTED. An observer never claims sight it no
        // longer maintains — the same rule the frontmost lane above keeps.
        let swept = sweptPlacesBox.withLock { places -> Set<AmbientPlace> in
            defer { places = [] }
            return places
        }
        for place in swept { store.forgetSurface(place: place) }
        lastSweepBox.withLock { $0 = nil }
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

    /// EVERY TAUGHT APPLICATION THAT IS RUNNING BUT NOT IN FRONT, once a sweep.
    ///
    /// PIN: A MACHINE IS NOT ONE WINDOW. The surface store has always been
    /// plural — one `AmbientSurface` per place — and only ever held one, because
    /// the only thing ever walked was whatever was frontmost. So "what is open
    /// on this Mac" could not be answered for anything the person was not
    /// looking at, and an application they had just left had no standing
    /// description at all.
    /// SIGHTED REGISTRATIONS ONLY, and that is the blast radius. A package that
    /// asked to be watched is one that declared how; nothing else is walked,
    /// ever, and `sweepLimit` bounds even that.
    /// SURFACES ONLY, NEVER A SLATE. The affordance slate is one-at-a-time by
    /// construction (`publishedBox`), and it belongs to whatever the person is
    /// actually looking at — a background window publishing offers would let
    /// `act_on_screen` reach a control nobody can see.
    func sweepStandingSurfaces(at now: Date, frontmostPID: pid_t?) {
        let due = lastSweepBox.withLock { last -> Bool in
            guard let last, now.timeIntervalSince(last) < Self.sweepInterval
            else { last = now; return true }
            return false
        }
        guard due else { return }

        let running = standingRunning()
        let claims = standingClaims().filter(\.hasEyes)
        var walked = 0
        for claim in claims {
            guard walked < Self.sweepLimit else { break }
            guard let process = running.first(where: { claim.owns(bundleID: $0.bundleID) }),
                  process.pid != frontmostPID,
                  process.bundleID != maryBundleID
            else { continue }
            guard let context = capture(process.pid) else { continue }
            let place = AmbientPlaceResolver.applicationPlace(
                forBundleID: process.bundleID)
            store.noteSurface(
                AmbientBridge.surface(from: context, place: place), at: now)
            sweptPlacesBox.withLock { $0.insert(place) }
            walked += 1
        }
        if walked > 0 {
            Self.log.debug("standing sweep walked \(walked, privacy: .public) application(s)")
        }
    }

    public func pollOnce(at now: Date = Date()) {
        // The sweep runs on its own clock whether or not anything is frontmost:
        // a machine with Mary in front still has the person's work behind her.
        sweepStandingSurfaces(at: now, frontmostPID: frontmost()?.pid)
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

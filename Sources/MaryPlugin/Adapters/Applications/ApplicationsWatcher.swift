//
//  ApplicationsWatcher.swift
//  MaryBrain
//
//  Live eyes for whatever app is frontmost — the generic case the four
//  bespoke watchers (Xcode, Scrivener, Pages, TextEdit) don't cover. Highlight
//  text in Notes, Mail, Safari, Messages, or any third-party app, and this
//  watcher notices without any app-specific scripting: `AXSelectionReader`
//  does the actual read, parameterized on whatever `NSWorkspace` says is
//  frontmost this tick.
//
//  A dedicated plugin may represent its application for richer context. Its
//  event/poll path gets first pass while it is healthy; the coordinator falls
//  back to this generic ability when that representation has no usable source
//  evidence. Applications are therefore context providers, not a hard-coded
//  exclusion list that can make selection disappear.
//
//  NO CONTEXT STRUCT, unlike the other four watchers. There is no per-app
//  document to describe (no name, no viewport, no git) — only "what's
//  highlighted, in which app, right now" — so this watcher publishes directly
//  into `AmbientContextStore` each tick rather than keeping a rich snapshot
//  box other code reads back. It has no debugger tile for the same reason
//  `AmbientWorldClass.perceptionOnly`'s own header gives: there is no single
//  bundle id to tile.
//
//  `promptContribution` always returns nil — the payload rides the ambient
//  store, read generically by the EXISTING heldFacts/heldMentions rendering
//  (`AmbientRanker.render`) that already consumes every world's facts. This
//  watcher's only job is to be a correct WRITER.
//

import AppKit
import Foundation
import os

public final class ApplicationsWatcher: MaryObserver, @unchecked Sendable {

    /// The outcome of one frontmost-app sample. `preserve` is distinct from
    /// an empty selection: when Mary's own reply surface takes focus, the
    /// user has not deselected anything in the source app. Clearing there
    /// raced the request and made a highlighted paragraph disappear just as
    /// the turn was being assembled.
    private enum PollResult: Sendable {
        case capture(
            AXSelectionReader.FocusedSelectionSample?, appName: String?, bundleID: String?)
        case preserve

        var hasSelection: Bool {
            if case .preserve = self { return true }
            guard case .capture(let sample, _, _) = self, let sample else { return false }
            if case .selected = sample.state { return true }
            return false
        }
    }

    public static let shared = ApplicationsWatcher()

    public let id = "other_apps_context"

    // Same cadence family as Pages/TextEdit — public so the debugger's
    // cadence display (if it ever grows one for this world) stays honest.
    public static let activeInterval: TimeInterval = 2.5
    public static let idleInterval: TimeInterval = 10
    private let pollerClaim = SinglePollerClaim()
    private let handoffRegistrationBox = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    @MainActor private var selectionGestureMonitor: Any?

    /// The focus signal this loop feeds — injectable so tests that activate
    /// a watcher can never pollute the process-wide tracker.
    private let focusTracker: WorkspaceFocusTracker
    /// The ambient context store this loop feeds. Same injection rule as the
    /// focus tracker, and for the same reason: a test that activates a
    /// watcher must not leak facts into the process-wide store.
    private let ambient: AmbientContextStore

    public init(
        focusTracker: WorkspaceFocusTracker = .shared,
        ambient: AmbientContextStore = .shared
    ) {
        self.focusTracker = focusTracker
        self.ambient = ambient
    }

    /// Whether the poll loop is running (the plugin is enabled and activated).
    public var isActive: Bool { pollerClaim.isActive }

    /// Mary's own UI is never a source text surface. Every other process is
    /// eligible: an enabled app representation contributes event capture and
    /// document enrichment, but it never unregisters the generic ability.
    static func shouldSkip(bundleID: String) -> Bool {
        bundleID == Bundle.main.bundleIdentifier
    }

    /// The generic ability owns capture for every app, including an app whose
    /// representation is temporarily unavailable. Preserve a known app's
    /// world on that raw packet so its representation can immediately render
    /// and enrich it when it wakes; unknown apps remain the one generic world.
    static func selectionWorld(for bundleID: String) -> AmbientWorld {
        selectionPlace(for: bundleID).world
    }

    /// The same question, answered as a PLACE so a registered application keeps
    /// its own lane instead of sharing the one generic bucket.
    ///
    /// THE REGISTRY ANSWERS. Bonnie opened this with three hardcoded bundle
    /// ids above the registry rung, on the reasoning that compiled identities
    /// were reserved and consulting the index first could only let a stale
    /// entry bypass a refusal. With no compiled applications there is nothing
    /// to reserve and nothing to bypass: a selection belongs to whichever
    /// registration claims the process, and to the shared lane when none does.
    ///
    /// An unregistered application still answers `.applications` with no
    /// lane — one shared perception world for every app Mary has been told
    /// nothing about.
    static func selectionPlace(for bundleID: String) -> AmbientPlace {
        // THE BROWSER WORKSPACE, ABOVE THE REGISTRY RUNG. SafariPlugin claims
        // BOTH browser bundles and its world is `.safari`, so the registry
        // below would file a CHROME highlight into `.lane(.safari)` while
        // the browser lead — and the browser's tab facts and elements — all
        // read `.application("browser")`. Highlight a paragraph in a Google Doc,
        // say "make this shorter", and the highlight would be held in a lane
        // the leading place cannot see. Selections belong where the eyes are.
        if AmbientPlaceResolver.isBrowser(bundleID: bundleID) {
            return AmbientPlaceResolver.browserPlace
        }
        if let registered = AmbientApplicationIndexProvider.current
            .registration(bundleID: bundleID) {
            return registered.place
        }
        return .lane(.applications)
    }

    // MARK: - MaryObserver

    /// Always nil — this watcher has no lane in `WorkspaceFocusArbiter` (it
    /// is not coding, and not "the writing app that owns the lead"); its
    /// output channel is the ambient store, read generically by the existing
    /// held-facts rendering. See this file's header.
    public func promptContribution() -> String? { nil }

    public var ambientSenses: Set<AmbientSense> { [.selection] }

    /// Capture immediately before prompt assembly instead of hoping the
    /// 2.5-second poll happened between a highlight and the user's request.
    /// When Mary is now frontmost, preserve the still-fresh source
    /// selection; see `PollResult.preserve`.
    public func refreshAmbientContext() async {
        publish(await pollTick())
    }

    public func activate() async {
        guard pollerClaim.claim({ [weak self] in await self?.pollLoop() }) else { return }
        let registration = SelectionHandoffCoordinator.shared.registerAnySource {
            [weak self] applicationID, trigger -> SelectionHandoffCoordinator.CaptureOutcome in
            self?.captureSelectionHandoff(from: applicationID, trigger: trigger) ?? .noEvidence
        }
        handoffRegistrationBox.withLock { current in
            if let current { SelectionHandoffCoordinator.shared.unregister(current) }
            current = registration
        }
        await installSelectionGestureMonitor()
        // Prime the store before returning so the very first turn already
        // sees a highlight that predates activation.
        publish(await pollTick())
    }

    public func deactivate() async {
        pollerClaim.release()
        let registration = handoffRegistrationBox.withLock { current -> UUID? in
            defer { current = nil }
            return current
        }
        if let registration { SelectionHandoffCoordinator.shared.unregister(registration) }
        await removeSelectionGestureMonitor()
        ambient.forgetPerceived(place: .lane(.applications))
    }

    /// Accessibility notifications are inconsistent across canvas editors,
    /// and a 2.5-second poll can easily miss highlight → click Mary. A mouse
    /// selection gesture is an Interaction event, so sample the still-frontmost
    /// source immediately at mouse-up. The coordinator still gives a specialist
    /// (Pages/TextEdit/etc.) first refusal and applies its normal source/focus
    /// authorization; this trigger never chooses a workspace by itself.
    @MainActor
    private func installSelectionGestureMonitor() {
        guard selectionGestureMonitor == nil else { return }
        selectionGestureMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { _ in
            Task { @MainActor in
                guard !ApplicationCopySelectionRecovery.suppressesSelectionGesture()
                else { return }
                guard let sourceID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                      sourceID != Bundle.main.bundleIdentifier
                else { return }
                Task.detached(priority: .userInitiated) {
                    // Canvas editors commonly commit AXSelectedTextRange one
                    // run-loop after mouse-up. Sample the source identity now,
                    // then give its accessibility tree a bounded settling
                    // window; coordinator authorization below still requires
                    // this exact application to own focus.
                    // Pages can enable Copy before its text system has
                    // committed the dragged selection to the pasteboard
                    // command. Live validation on Pages 14.5 showed 60 ms
                    // consistently too early and 200 ms reliable; retain a
                    // small margin without making the interaction perceptible.
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !ApplicationCopySelectionRecovery.suppressesSelectionGesture()
                    else { return }
                    _ = await SelectionHandoffCoordinator.shared.captureOutcomeAsync(
                        applicationID: sourceID,
                        trigger: .activeSourcePreflight)
                }
            }
        }
    }

    @MainActor
    private func removeSelectionGestureMonitor() {
        guard let selectionGestureMonitor else { return }
        NSEvent.removeMonitor(selectionGestureMonitor)
        self.selectionGestureMonitor = nil
    }

    // MARK: - Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            let result = await pollTick()
            publish(result)
            let interval = result.hasSelection ? Self.activeInterval : Self.idleInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// One poll: the frontmost app's live selection, or nil for "nothing to
    /// publish" (no app frontmost, a skipped workspace app, no selection, a
    /// secure field, or AX untrusted — `AXSelectionReader.read` folds all of
    /// these into one honest nil rather than distinguishing them, since none
    /// of them earns a prompt line the way a denied Automation grant does for
    /// the richer, single-app watchers).
    private func pollTick() async -> PollResult {
        // Feeds the coding/writing focus arbiter, exactly as every other
        // watcher loop does — harmless here since `record(bundleID:)` only
        // recognizes the four workspace bundle ids and no-ops otherwise, but
        // it keeps headless-probe parity with the rest of the tree.
        focusTracker.sample()
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier
        else { return .capture(nil, appName: nil, bundleID: nil) }
        // A request typed into Mary necessarily brings Mary forward. The
        // preceding app's selection is still the user's direct referent for
        // the short attention lease, so this is not a deselection event.
        if bundleID == Bundle.main.bundleIdentifier { return .preserve }
        guard !Self.shouldSkip(bundleID: bundleID) else {
            return .capture(nil, appName: nil, bundleID: nil)
        }
        let sample = AXSelectionReader.sourceSelectionSample(pid: front.processIdentifier)
        return .capture(sample, appName: front.localizedName, bundleID: bundleID)
    }

    /// ONE publish seam, injectable-testable: called with the source sample rather
    /// than reaching into `NSWorkspace`/AX itself, so the wiring into
    /// `replacePerceived`/`forgetPerceived` is checkable with a synthetic
    /// reading even though a real one can't be produced in a test process.
    private func publish(_ result: PollResult) {
        guard case let .capture(sample, appName, bundleID) = result else { return }
        // `AXSelectionReader` can block. Re-check the exact process after it
        // returns so a poll that began in TextEdit/Pages cannot publish an old
        // highlight after the user has moved to another source.
        guard let sample, let bundleID,
              SelectionHandoffCoordinator.shared.sourceStillOwnsFocus(
                applicationID: bundleID, processID: sample.processID)
        else { return }
        publish(sample, appName: appName, bundleID: bundleID)
    }

    func publish(
        _ sample: AXSelectionReader.FocusedSelectionSample?,
        appName: String?, bundleID: String? = nil
    ) {
        guard let sample, let bundleID else { return }
        _ = SelectionHandoffPublisher.publish(
            sample,
            ambient: ambient,
            place: Self.selectionPlace(for: bundleID),
            applicationID: bundleID,
            subject: appName,
            channel: .sourcePoll)
    }

    /// The generic source ability is invoked for every app deactivation, but
    /// a dedicated representation gets the first attempt. The coordinator
    /// reaches this fallback only when that attempt produced no evidence, so
    /// registration alone must not reject the handoff here.
    private func captureSelectionHandoff(
        from applicationID: String,
        trigger: SelectionHandoffCoordinator.CaptureTrigger
    ) -> SelectionHandoffCoordinator.CaptureOutcome {
        guard applicationID != Bundle.main.bundleIdentifier,
              !Self.shouldSkip(bundleID: applicationID),
              let process = NSRunningApplication
                .runningApplications(withBundleIdentifier: applicationID)
                .first
        else { return .noEvidence }
        let sample = AXSelectionReader.sourceSelectionSample(
            pid: process.processIdentifier)
        guard SelectionHandoffCoordinator.shared.acceptsCapturedSelection(
            applicationID: applicationID,
            processID: process.processIdentifier,
            trigger: trigger)
        else { return .noEvidence }
        return SelectionHandoffPublisher.captureOutcome(
            sample,
            ambient: ambient,
            place: Self.selectionPlace(for: applicationID),
            applicationID: applicationID,
            subject: process.localizedName,
            channel: .applicationHandoff,
            clearCaret: trigger == .activeSourcePreflight)
    }
}

/// The generic watcher's support bundle — the `PagesSupport`/`TextEditSupport`
/// shape, so the runtime activates and consults it the same way.
public struct ApplicationsSupport: Sendable {
    public let watcher: ApplicationsWatcher

    public init(watcher: ApplicationsWatcher) {
        self.watcher = watcher
    }

    public static let shared = ApplicationsSupport(watcher: .shared)

    public var all: [any MaryObserver] { [watcher] }
}

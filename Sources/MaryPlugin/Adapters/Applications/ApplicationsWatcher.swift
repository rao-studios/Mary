//
//  ApplicationsWatcher.swift
//  MaryBrain
//
//  WHAT: Generic frontmost-app selection watcher.
//  IN:   AXSelectionReader / NSWorkspace / SelectionHandoffCoordinator
//  OUT:  AmbientContextStore (writer only — promptContribution is nil)
//  PIN:  Dedicated plugins get first pass; this is fallback. No context struct.
//

import AppKit
import Foundation
import os

public final class ApplicationsWatcher: MaryObserver, @unchecked Sendable {

    /// One frontmost sample. `preserve` ≠ empty: Mary's UI taking focus is not a deselection.
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

    // Same cadence family as Pages/TextEdit.
    public static let activeInterval: TimeInterval = 2.5
    public static let idleInterval: TimeInterval = 10
    private let pollerClaim = SinglePollerClaim()
    private let handoffRegistrationBox = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    @MainActor private var selectionGestureMonitor: Any?

    /// Focus signal this loop feeds. Injectable so tests never pollute the process-wide tracker.
    private let focusTracker: WorkspaceFocusTracker
    /// Ambient store this loop feeds. Same injection rule as the focus tracker.
    private let ambient: AmbientContextStore

    public init(
        focusTracker: WorkspaceFocusTracker = .shared,
        ambient: AmbientContextStore = .shared
    ) {
        self.focusTracker = focusTracker
        self.ambient = ambient
    }

    /// Whether the poll loop is running.
    public var isActive: Bool { pollerClaim.isActive }

    /// Mary's own UI is never a source. Other processes stay eligible.
    static func shouldSkip(bundleID: String) -> Bool {
        bundleID == Bundle.main.bundleIdentifier
    }

    /// Preserve a known app's world so its representation can enrich when it wakes.
    static func selectionWorld(for bundleID: String) -> AmbientWorld {
        selectionPlace(for: bundleID).world
    }

    /// Place so a registered app keeps its own lane. Unregistered → `.applications`.
    static func selectionPlace(for bundleID: String) -> AmbientPlace {
        // Browsers above the registry: selections belong where the eyes are, not `.safari`.
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

    /// Always nil — output is the ambient store, not WorkspaceFocusArbiter.
    public func promptContribution() -> String? { nil }

    public var ambientSenses: Set<AmbientSense> { [.selection] }

    /// Capture immediately before prompt assembly. Mary frontmost → preserve (PollResult.preserve).
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
        // Prime the store so the first turn sees a highlight that predates activation.
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

    /// Mouse-up samples the still-frontmost source. Coordinator still gives specialists first refusal.
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
                    // Canvas editors commit AXSelectedTextRange one run-loop after mouse-up.
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

    /// Frontmost live selection, or nil (no app, skipped, empty, secure, AX untrusted).
    private func pollTick() async -> PollResult {
        // Feeds the coding/writing focus arbiter — same as other watcher loops.
        focusTracker.sample()
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier
        else { return .capture(nil, appName: nil, bundleID: nil) }
        // Mary taking focus is not a deselection — keep the preceding app's selection.
        if bundleID == Bundle.main.bundleIdentifier { return .preserve }
        guard !Self.shouldSkip(bundleID: bundleID) else {
            return .capture(nil, appName: nil, bundleID: nil)
        }
        let sample = AXSelectionReader.sourceSelectionSample(pid: front.processIdentifier)
        return .capture(sample, appName: front.localizedName, bundleID: bundleID)
    }

    /// One publish seam. Takes a sample so tests can inject without NSWorkspace/AX.
    private func publish(_ result: PollResult) {
        guard case let .capture(sample, appName, bundleID) = result else { return }
        // AXSelectionReader can block. Re-check the process so a moved-away poll cannot publish.
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

    /// Fallback when a dedicated representation produced no evidence. Registration alone must not reject.
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

/// Generic watcher's support bundle — same activate/consult shape as other surface supports.
public struct ApplicationsSupport: Sendable {
    public let watcher: ApplicationsWatcher

    public init(watcher: ApplicationsWatcher) {
        self.watcher = watcher
    }

    public static let shared = ApplicationsSupport(watcher: .shared)

    public var all: [any MaryObserver] { [watcher] }
}

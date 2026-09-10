//
//  WindowManagement.swift
//  MaryPlugin
//
//  WHAT: Machine contract for window management — resolve, then act.
//  IN:   WindowManagementPlugin / WindowManagementModels
//  OUT:  WindowManagementAdapter registry / VerifiedActivation / StagedWritingSurface
//  PIN:  No application-specific policy. Adapter order is preference order.
//

import AppKit
import Foundation
import MaryComputerUse

/// Coordinates resolution and chooses an adapter. Adapter order is preference order.
public final class WindowManagementService: WindowManagementServing, @unchecked Sendable {
    public static let live = WindowManagementService(
        resolver: NSWorkspaceApplicationResolver(),
        adapters: [AccessibilityWindowManagementAdapter()])

    private let resolver: any WindowApplicationResolving
    private let adapters: [any WindowManagementAdapter]
    /// Spoken reference → window, via the owning application's watcher.
    /// Nil/`.none` when the app declares no prose surface.
    private let referenceResolver: @Sendable (String) -> WindowReferenceDecision
    /// Plain title with no conversation evidence — unique-match-or-nil, never launching.
    private let titleProbe: @Sendable (String) async -> ManagedWindowReference?

    init(
        resolver: any WindowApplicationResolving,
        adapters: [any WindowManagementAdapter],
        referenceResolver: @escaping @Sendable (String) -> WindowReferenceDecision = { _ in .none },
        titleProbe: @escaping @Sendable (String) async -> ManagedWindowReference? = { _ in nil }
    ) {
        self.resolver = resolver
        self.adapters = adapters
        self.referenceResolver = referenceResolver
        self.titleProbe = titleProbe
    }

    public func activateApplication(named application: String) async -> WindowManagementResult {
        let wasRunning = (try? resolver.runningApplication(named: application).get()) != nil
        switch await resolver.activateApplication(named: application) {
        case .success(let resolved):
            let verb = wasRunning ? "Brought" : "Opened"
            return WindowManagementResult(
                ok: true, summary: "\(verb) \(resolved.displayName) forward.")
        case .failure(let error):
            return .failure(error)
        }
    }

    public func listWindows(application: String) async -> WindowManagementResult {
        do {
            let (app, _, windows) = try await resolvedWindows(application: application)
            let rows = windows.map { window in
                var state: [String] = []
                if window.index == 1 { state.append("front") }
                if window.isMinimized == true { state.append("minimized") }
                let suffix = state.isEmpty ? "" : " — " + state.joined(separator: ", ")
                return "[\(window.id)] \(window.title.isEmpty ? "Untitled" : window.title)\(suffix)"
            }
            let noun = windows.count == 1 ? "window" : "windows"
            return WindowManagementResult(
                ok: true,
                summary: "\(windows.count) \(noun) open in \(app.displayName):\n"
                    + rows.joined(separator: "\n"),
                windows: windows)
        } catch let error as WindowManagementError {
            return .failure(error)
        } catch {
            return .failure(.operationFailed("I couldn't list that application's windows."))
        }
    }

    public func restoreWindow(application: String, window: String) async -> WindowManagementResult {
        await targetOperation(application: application, reference: window, verb: "Restored") {
            try await $0.adapter.restore($0.window, in: $0.application)
        }
    }

    public func raiseWindow(application: String, window: String) async -> WindowManagementResult {
        await targetOperation(application: application, reference: window, verb: "Brought forward") {
            try await $0.adapter.raise($0.window, in: $0.application)
            // Raise verified activation and the exact window — typer staging.
            if SelectionSurfacePolicy.permitsProseApplication($0.application.bundleIdentifier) {
                StagedWritingSurface.shared.record(
                    bundleID: $0.application.bundleIdentifier,
                    spokenName: $0.application.displayName)
            }
        }
    }

    public func raiseAllWindows(application: String) async -> WindowManagementResult {
        do {
            let (app, adapter, windows) = try await resolvedWindows(application: application)
            let count = try await adapter.raiseAll(windows, in: app)
            if SelectionSurfacePolicy.permitsProseApplication(app.bundleIdentifier) {
                StagedWritingSurface.shared.record(
                    bundleID: app.bundleIdentifier, spokenName: app.displayName)
            }
            let noun = count == 1 ? "window" : "windows"
            return WindowManagementResult(
                ok: true, summary: "Brought all \(count) \(app.displayName) \(noun) forward.")
        } catch let error as WindowManagementError {
            return .failure(error)
        } catch {
            return .failure(.operationFailed("I couldn't bring that application's windows forward."))
        }
    }

    public func setFullScreen(
        application: String, window: String, enabled: Bool
    ) async -> WindowManagementResult {
        do {
            let inferred = await inferredTarget(
                explicit: application, windowReference: window)
            if let failure = inferred.failure { throw failure }
            let (app, adapter, windows) = try await resolvedWindows(
                application: inferred.application)
            // Omitted reference = front window. Other verbs may act behind; this one does not.
            let target: ManagedWindow
            if inferred.reference.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty {
                target = windows[0]
            } else {
                target = try await adapter.resolve(
                    inferred.reference, in: app, windows: windows)
            }
            try await adapter.setFullScreen(target, in: app, enabled: enabled)
            let title = target.title.isEmpty ? "That window" : target.title
            return WindowManagementResult(
                ok: true,
                summary: enabled
                    ? "\(title) is full screen now."
                    : "\(title) is out of full screen.")
        } catch let error as WindowManagementError {
            return .failure(error)
        } catch {
            return .failure(.operationFailed("I couldn't switch that window's full screen."))
        }
    }

    private typealias Target = (
        application: ManagedApplication,
        adapter: any WindowManagementAdapter,
        window: ManagedWindow
    )

    private struct InferredTarget {
        var application: String
        var reference: String
        var failure: WindowManagementError?

        init(
            application: String,
            reference: String,
            failure: WindowManagementError? = nil
        ) {
            self.application = application
            self.reference = reference
            self.failure = failure
        }
    }

    private func targetOperation(
        application: String,
        reference: String,
        verb: String,
        operation: @Sendable (Target) async throws -> Void
    ) async -> WindowManagementResult {
        do {
            let inferred = await inferredTarget(
                explicit: application, windowReference: reference)
            if let failure = inferred.failure { throw failure }
            let (app, adapter, windows) = try await resolvedWindows(
                application: inferred.application)
            let target = try await adapter.resolve(
                inferred.reference, in: app, windows: windows)
            try await operation((app, adapter, target))
            let title = target.title.isEmpty ? "That window" : target.title
            return WindowManagementResult(ok: true, summary: "\(verb) \(title) in \(app.displayName).")
        } catch let error as WindowManagementError {
            return .failure(error)
        } catch {
            return .failure(.operationFailed("I couldn't manage that window."))
        }
    }

    private func resolvedWindows(
        application: String
    ) async throws -> (ManagedApplication, any WindowManagementAdapter, [ManagedWindow]) {
        let app = try resolver.runningApplication(named: application).get()
        guard let adapter = adapters.first(where: { $0.supports(application: app) }) else {
            throw WindowManagementError.operationFailed(
                "No installed adapter can manage \(app.displayName)'s windows.")
        }
        let windows = try await adapter.windows(in: app).sorted { $0.index < $1.index }
        guard !windows.isEmpty else { throw WindowManagementError.noWindows(app.displayName) }
        return (app, adapter, windows)
    }

    /// Resolve ownership; canonicalize to a stable id when the owner answers.
    /// PIN: omitted app = frontmost. Generic AX ids lead with pid.
    private func inferredTarget(
        explicit: String, windowReference: String
    ) async -> InferredTarget {
        let named = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = windowReference.trimmingCharacters(in: .whitespacesAndNewlines)

        // Owning application's watcher answers first. `.none` falls through.
        if !named.isEmpty {
            switch referenceResolver(reference) {
            case .resolved(let window):
                return InferredTarget(application: named, reference: window.identity)
            case .ownedButUnresolved(let failure):
                return InferredTarget(
                    application: named, reference: reference, failure: failure)
            case .none:
                return InferredTarget(application: named, reference: reference)
            }
        }

        switch referenceResolver(reference) {
        case .resolved(let window):
            return InferredTarget(
                application: window.applicationID, reference: window.identity)
        case .ownedButUnresolved(let failure):
            // Owner known, member not unique — terminal; do not try a looser resolver.
            return InferredTarget(
                application: "", reference: reference, failure: failure)
        case .none:
            break
        }
        let raw = reference.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let first = raw.split(separator: ":", maxSplits: 1).first,
           let pid = pid_t(first),
           let running = NSRunningApplication(processIdentifier: pid) {
            return InferredTarget(
                application: running.bundleIdentifier ?? running.localizedName ?? "",
                reference: reference)
        }
        // Unique live-roster title match after conversation rungs. Tie/miss → frontmost.
        if !reference.isEmpty, let window = await titleProbe(reference) {
            return InferredTarget(
                application: window.applicationID, reference: window.identity)
        }
        return InferredTarget(application: "", reference: reference)
    }
}

/// Application lookup and activation. Query strings never interpolate into a shell.
final class NSWorkspaceApplicationResolver: WindowApplicationResolving, @unchecked Sendable {
    private static let activationTimeout: TimeInterval = 2.0
    private static let launchTimeout: TimeInterval = 5.0

    func runningApplication(named application: String) -> Result<ManagedApplication, WindowManagementError> {
        let query = application.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  let value = Self.value(frontmost)
            else { return .failure(.invalidApplication) }
            return .success(value)
        }
        return Self.resolve(query, candidates: NSWorkspace.shared.runningApplications.compactMap(Self.value))
    }

    func activateApplication(named application: String) async -> Result<ManagedApplication, WindowManagementError> {
        let query = application.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure(.invalidApplication) }

        switch runningApplication(named: query) {
        case .success(let running):
            // Two-road verified activation (VerifiedActivation).
            let raised = await VerifiedActivation.bringForward(
                pid: running.processIdentifier)
            if let refusal = raised.reason(app: running.displayName) {
                return .failure(.operationFailed(refusal))
            }
            // Proven fronting — typer resolve ladder.
            if SelectionSurfacePolicy.permitsProseApplication(running.bundleIdentifier) {
                StagedWritingSurface.shared.record(
                    bundleID: running.bundleIdentifier,
                    spokenName: running.displayName)
            }
            return .success(running)
        case .failure(.ambiguousApplication(let name)):
            return .failure(.ambiguousApplication(name))
        case .failure(.invalidApplication):
            return .failure(.invalidApplication)
        case .failure:
            break
        }

        let arguments: [String]
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) != nil {
            arguments = ["-b", query]
        } else {
            arguments = ["-a", query]
        }
        do {
            let opened = try await Subprocess.run("/usr/bin/open", arguments, timeout: 15)
            guard opened.exitCode == 0 else { return .failure(.applicationNotFound(query)) }
        } catch {
            return .failure(.operationFailed("I couldn't open \(query)."))
        }

        // Wait for the process, then VerifiedActivation. Do not poll frontmost here.
        let deadline = Date().addingTimeInterval(Self.launchTimeout)
        var lastRunning: ManagedApplication?
        while Date() < deadline {
            if case .success(let running) = runningApplication(named: query) {
                lastRunning = running
                break
            }
            if Task.isCancelled {
                return .failure(.operationFailed("Opening \(query) was cancelled."))
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let running = lastRunning else { return .failure(.applicationNotFound(query)) }
        let raised = await VerifiedActivation.bringForward(
            pid: running.processIdentifier,
            timeout: max(1.0, deadline.timeIntervalSinceNow))
        if raised.failure == .cancelled {
            return .failure(.operationFailed("Opening \(query) was cancelled."))
        }
        if let refusal = raised.reason(app: running.displayName) {
            return .failure(.operationFailed(refusal))
        }
        return .success(running)
    }

    static func resolve(
        _ application: String,
        candidates: [ManagedApplication]
    ) -> Result<ManagedApplication, WindowManagementError> {
        let query = normalize(application)
        guard !query.isEmpty else { return .failure(.invalidApplication) }

        let exact = candidates.filter {
            normalize($0.bundleIdentifier) == query || normalize($0.displayName) == query
        }
        if let selected = uniqueApplication(exact) { return .success(selected) }
        if distinctApplications(exact).count > 1 { return .failure(.ambiguousApplication(application)) }

        let partial = candidates.filter {
            let id = normalize($0.bundleIdentifier)
            let name = normalize($0.displayName)
            return id.hasPrefix(query) || name.hasPrefix(query)
                || id.contains(query) || name.contains(query)
        }
        if let selected = uniqueApplication(partial) { return .success(selected) }
        if distinctApplications(partial).count > 1 {
            return .failure(.ambiguousApplication(application))
        }
        return .failure(.applicationNotRunning(application))
    }

    private static func uniqueApplication(_ candidates: [ManagedApplication]) -> ManagedApplication? {
        let distinct = distinctApplications(candidates)
        guard distinct.count == 1 else { return nil }
        return candidates.sorted { $0.processIdentifier < $1.processIdentifier }.first
    }

    private static func distinctApplications(_ candidates: [ManagedApplication]) -> Set<String> {
        Set(candidates.map { normalize($0.bundleIdentifier) + "|" + normalize($0.displayName) })
    }

    /// Collapse interior whitespace too — ASR says "text edit" for TextEdit.
    /// PIN: WindowReferenceResolver keeps spaces ("Untitled 9" ≠ "Untitled9").
    private static func normalize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })).lowercased()
    }

    private static func value(_ application: NSRunningApplication) -> ManagedApplication? {
        guard !application.isTerminated,
              let bundleID = application.bundleIdentifier,
              let name = application.localizedName
        else { return nil }
        return ManagedApplication(
            bundleIdentifier: bundleID,
            displayName: name,
            processIdentifier: application.processIdentifier)
    }

}

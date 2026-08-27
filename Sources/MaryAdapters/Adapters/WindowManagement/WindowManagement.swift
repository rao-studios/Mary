//
//  WindowManagement.swift
//  MaryBrain
//
//  The machine-level contract behind the window-management ability. The
//  ability owns the verbs; application plugins contribute preferred adapters
//  when their native automation surface is more precise than Accessibility.
//

import AppKit
import Foundation

/// Coordinates resolution and chooses an adapter; it contains no application-
/// specific policy. Adapter order is the explicit preference order.
public final class WindowManagementService: WindowManagementServing, @unchecked Sendable {
    public static let live = WindowManagementService(
        resolver: NSWorkspaceApplicationResolver(),
        adapters: [AccessibilityWindowManagementAdapter()])

    private let resolver: any WindowApplicationResolving
    private let adapters: [any WindowManagementAdapter]
    /// RESOLVES A SPOKEN WINDOW REFERENCE TO A WINDOW, for whichever
    /// application owns the reference.
    ///
    /// Bonnie's version of this pair named TextEdit in the type, the property
    /// and the default — `textEditReferenceResolver`, returning a
    /// `TextEditWindowReferenceDecision`. The SEAM was right (already injected,
    /// so the ownership ladder is testable without running an application);
    /// only the name was wrong. A prose surface's watcher supplies this, and
    /// an application that declares no prose surface simply never resolves,
    /// which is `.none` and correct.
    private let referenceResolver: @Sendable (String) -> WindowReferenceDecision
    /// A plain window title with no conversation evidence, asked of the LIVE
    /// roster — unique-match-or-nil, tie-refusing, never launching.
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
            // The raise verified activation AND raised the exact window —
            // proven, window-accurate staging for the typer's resolve ladder.
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
            // "IT" IS THE FRONT WINDOW. Every other verb here requires a
            // reference because it may act on a window behind the one in
            // view; this one is asked about the thing being looked at, and
            // demanding a title for it would be a question nobody would ask
            // a person.
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

    /// Resolve application ownership and, when TextEdit conversation evidence
    /// supplies it, canonicalise the window to stable identity in one step.
    /// Passing the canonical id into the adapter prevents a later z-order or
    /// title lookup from deriving a different answer.
    ///
    /// A stable reference may prove its owning application. TextEdit uses its
    /// native id prefix, a conversation `[W#]` handle, an established exact
    /// title, or a uniquely targeted conversational follow-up. Generic AX ids
    /// lead with pid. Otherwise an omitted app honestly means the frontmost
    /// app.
    private func inferredTarget(
        explicit: String, windowReference: String
    ) async -> InferredTarget {
        let named = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = windowReference.trimmingCharacters(in: .whitespacesAndNewlines)

        // THE OWNING APPLICATION ANSWERS FOR ITS OWN WINDOWS. Bonnie's
        // version of this ladder opened with three TextEdit-shaped arms: a
        // bundle-id comparison against two spellings of the name, a
        // `textedit:` reference prefix, and a regex for that application's
        // unsaved-title family (`^untitled \d+$`). Each was correct and each
        // was a compiled application inside a service whose own header says
        // it "contains no application-specific policy".
        //
        // What replaces them is the seam that was already here: a resolver
        // the owning application's watcher supplies. An application that
        // declares a prose surface resolves its own references — including
        // its own untitled family, which only it knows the shape of — and one
        // that declares none answers `.none` and falls through to the generic
        // rungs below.
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
            // The application is known but its member was not uniquely
            // resolved. This is terminal: passing the raw phrase into a
            // looser resolver below would let that one derive a second — and
            // potentially different — answer.
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
        // A plain title with no conversation evidence still deserves the
        // application that actually owns it. "Bring the Shopping List window
        // forward" used to fall to the frontmost app — usually not TextEdit —
        // and die there as windowNotFound. Ask the live TextEdit roster LAST,
        // after every conversation-owned rung, and accept only a UNIQUE title
        // match; a tie inside TextEdit or a miss falls through to the
        // frontmost contract unchanged. When the frontmost app also owns the
        // title, the owner wins — deliberate, because the status quo was not
        // "the other app wins", it was a refusal; an explicit `app` argument
        // (or conversation evidence, which runs earlier) overrides.
        if !reference.isEmpty, let window = await titleProbe(reference) {
            return InferredTarget(
                application: window.applicationID, reference: window.identity)
        }
        return InferredTarget(application: "", reference: reference)
    }
}

/// Application lookup and activation remain Mary-owned. Query strings are
/// never interpolated into a shell: `/usr/bin/open` receives an argv array.
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
            // Two-road verified activation — cooperative activation alone
            // refuses silently from a background caller (the "TextEdit didn't
            // come forward" incident); the Apple Events road is the retry it
            // cannot refuse the same way.
            let raised = await VerifiedActivation.bringForward(
                pid: running.processIdentifier)
            if let refusal = raised.reason(app: running.displayName) {
                return .failure(.operationFailed(refusal))
            }
            // Proven fronting: the raised app is now typing-destination
            // evidence for the typer's resolve ladder.
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

        // WAIT FOR THE PROCESS, THEN HAND IT TO THE ONE AUTHORITY.
        //
        // This loop used to do its own activation, and it carried all three of
        // the defects `VerifiedActivation` exists to fix: `activate(options: [])`
        // (no `.activateAllWindows`, no unhide, and no Apple Events road),
        // exactly one activation attempt with the remaining seconds spent only
        // polling, and — worst — a `NSWorkspace.frontmostApplication` read from
        // this background executor, which is the stale-cache condition that
        // reports a successful raise as a failure. A cold launch could put the
        // app on screen and still answer "opened but didn't come to the
        // foreground", and `MaryBrain+Lanes` reads that as grounds to try a
        // different application entirely.
        //
        // So the loop now waits for the PROCESS to exist — the one thing that
        // genuinely needs polling after `open` — and the raise is one verified
        // call, main-actor checked, two roads.
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

    /// INTERIOR whitespace goes too, not just the edges. ASR renders
    /// "TextEdit" as "text edit", and a two-word query matched neither the
    /// display name nor the bundle id by equality, prefix, or containment —
    /// so every verb answered "text edit isn't open" at a machine with
    /// TextEdit right there on screen. This is the APP resolver's normalize
    /// only; `WindowReferenceResolver` keeps its spaces, because collapsing
    /// them there would merge the window titles "Untitled 9" and "Untitled9".
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

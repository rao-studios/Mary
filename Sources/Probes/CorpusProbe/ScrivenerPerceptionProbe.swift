//
//  ScrivenerPerceptionProbe.swift
//  CorpusProbe
//
//  WHAT: Corpus-backed workspace perception via real dispatch (type_at_cursor).
//  OUT:  CLI: mary-corpus-probe --dispatch-scrivener-typing […]
//  PIN:  list/read/create_document stay absent (binder ≠ one text element).
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum ScrivenerPerceptionProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("--dispatch-scrivener-typing")
            && !arguments.contains("--dispatch-scrivener-typing-explicit-app")
    }

    static func shouldRunExplicitApp(_ arguments: [String]) -> Bool {
        arguments.contains("--dispatch-scrivener-typing-explicit-app")
    }

    static func shouldRunFrontmostOnly(_ arguments: [String]) -> Bool {
        arguments.contains("--dispatch-scrivener-typing-frontmost-only")
    }

    static func run(_ arguments: [String]) async {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted for this binary. Use ./scripts/dev.sh.")
            exit(1)
        }

        heading("the roster")
        let adapters = MaryAdapterCatalog.adapters()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: MaryAdapterCatalog.observers()),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        check(load.activated, "the packages loaded", "\(load.snapshot.records.count)")
        for issue in load.issues where issue.severity == .error {
            print("      ! \(issue.code): \(issue.message)")
        }

        let registrations = MaryRuntime.corpusRegistrations(from: load.snapshot)
        CorpusSupport.shared.reconcile(registrations)
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        AmbientApplicationBridge.install(profiles: profiles)

        // THE COMPILED PERCEPTION, straight off the graph — not a hand-picked
        // stand-in. This is what changes when `PluginCompiler.perception`
        // gains the `corpus` channel.
        let scrivenerProfile = profiles.first { $0.id == "scrivener" }
        check(scrivenerProfile != nil, "scrivener.mary compiled a profile")
        let perceptionKind = scrivenerProfile?.perception?.kind
        check(perceptionKind == .workspace,
              "its compiled perception is .workspace, not .perceptionOnly",
              perceptionKind.map(String.init(describing:)) ?? "nil")

        heading("what is open")
        guard case .success(let corpus) = ProjectCorpusSupport.resolve(nil) else {
            print("  ✗ Scrivener's project didn't resolve unambiguously. Open exactly one "
                + "manuscript in Scrivener (close other corpus-backed windows, e.g. Xcode) "
                + "and try again.")
            exit(1)
        }
        check(corpus.registration.applicationID == "scrivener",
              "the resolved corpus is Scrivener's", corpus.name)

        let activation = await VerifiedActivation.bringForward(
            pid: corpus.processIdentifier, requireVisibleWindow: true)
        check(activation.succeeded, "Scrivener came forward",
              activation.road.map(String.init(describing:))
                  ?? activation.reason(app: corpus.registration.displayName) ?? "refused")

        heading("the real lead")
        WorkspaceFocusTracker.shared.sample()
        let signal = WorkspaceFocusTracker.shared.signal()
        let leadApplicationID = signal.lead?.application
        check(leadApplicationID == "scrivener",
              "the tracker's own frontmost read leads with Scrivener",
              leadApplicationID ?? "none")

        let utterance = value("--utterance") ?? "type this at the cursor"
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: utterance,
            leadApplicationID: leadApplicationID,
            profiles: profiles))
        AmbientContextStore.shared.noteUtterance(utterance)
        AmbientContextStore.shared.noteRoute(route)
        check(route.leadPlace?.application == "scrivener",
              "the route's lead place names Scrivener",
              route.leadPlace?.token ?? "none")
        check(route.leadPlace?.hasEyes == true,
              "the place now reports hasEyes — the fix this probe exists for")
        check(route.leadPlace?.focus == .writing,
              "and its discipline is writing",
              route.leadPlace?.focus.map(String.init(describing:)) ?? "none")

        heading("what the model would actually be offered")
        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let offered = Set(runtime.schemas.map(\.name))
        check(offered.contains("type_at_cursor"), "type_at_cursor is in this turn's roster")
        // Roster still offers list/read/create_document. Resolve refuses Scrivener (no proseSurface).
        check(offered.contains("list_documents"),
              "list_documents IS offered (ability-level, not app-gated — expected)")

        heading("dispatching list_documents for real — must NOT act on Scrivener")
        let listOutcome = await runtime.dispatch(name: "list_documents", argumentsJSON: "{}")
        check(listOutcome.ok, "list_documents dispatched without a hard error")
        check(listOutcome.foundNothing,
              "and it found nothing — Scrivener is not a registered prose surface",
              listOutcome.summary)
        check(!listOutcome.summary.lowercased().contains("gitas-ballad")
                && !listOutcome.summary.lowercased().contains("scrivener"),
              "its answer names neither the manuscript nor Scrivener",
              listOutcome.summary)

        heading("dispatching type_at_cursor for real")
        // Revertible marker; no explicit `app` — exercises the frontmost rung.
        let marker = value("--marker") ?? " [[MARY-PROBE-\(Int(Date().timeIntervalSince1970))]]"
        let typeOutcome = await runtime.dispatch(
            name: "type_at_cursor",
            argumentsJSON: #"{"text":"\#(marker)"}"#)
        check(typeOutcome.ok, "type_at_cursor dispatched without a refusal", typeOutcome.summary)
        if !typeOutcome.ok {
            print("""

              ✗ type_at_cursor refused. If the refusal text mentions "a text \
                cursor", place a real cursor in a Scrivener document's editor \
                pane (click into it) and run this again.
            """)
        }

        AmbientContextStore.shared.noteRoute(route)
    }

    // MARK: - The explicit-app rung, on its own

    /// Explicit `app` while Scrivener is backgrounded — taught-application rung.
    static func runExplicitApp(_ arguments: [String]) async {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted for this binary. Use ./scripts/dev.sh.")
            exit(1)
        }

        heading("the roster")
        let adapters = MaryAdapterCatalog.adapters()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: MaryAdapterCatalog.observers()),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        check(load.activated, "the packages loaded", "\(load.snapshot.records.count)")
        for issue in load.issues where issue.severity == .error {
            print("      ! \(issue.code): \(issue.message)")
        }

        let registrations = MaryRuntime.corpusRegistrations(from: load.snapshot)
        CorpusSupport.shared.reconcile(registrations)
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        AmbientApplicationBridge.install(profiles: profiles)

        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier?.hasPrefix("com.literatureandlatte.scrivener") == true
        }) else {
            print("  ✗ Scrivener isn't running. Open it with a project and try again.")
            exit(1)
        }

        heading("bringing a DIFFERENT application forward first")
        // Finder first so Scrivener is backgrounded before the explicit-app dispatch.
        let awayActivation = await VerifiedActivation.bringForward(
            bundleID: "com.apple.finder", requireVisibleWindow: false)
        check(awayActivation.succeeded, "Finder came forward",
              awayActivation.road.map(String.init(describing:))
                  ?? awayActivation.reason(app: "Finder") ?? "refused")
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        check(
            frontBefore?.hasPrefix("com.literatureandlatte.scrivener") != true,
            "Scrivener is NOT frontmost going into the dispatch below",
            frontBefore ?? "none")

        heading("dispatching type_at_cursor with an EXPLICIT app, Scrivener in the background")
        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        // Explicit `app:"Scrivener"` hits taughtSurface; family match, not exact bundle id.
        let marker = value("--marker")
            ?? " [[MARY-PROBE-EXPLICIT-\(Int(Date().timeIntervalSince1970))]]"
        let typeOutcome = await runtime.dispatch(
            name: "type_at_cursor",
            argumentsJSON: #"{"app":"Scrivener","text":"\#(marker)"}"#)
        check(typeOutcome.ok, "type_at_cursor dispatched without a refusal", typeOutcome.summary)
        check(
            !typeOutcome.summary.lowercased().contains("open scrivener first"),
            "and specifically not the exact-match misfire this probe exists to catch",
            typeOutcome.summary)
        if !typeOutcome.ok {
            print("""

              ✗ type_at_cursor refused. If the refusal text mentions "a text \
                cursor", place a real cursor in a Scrivener document's editor \
                pane (click into it) and run this again.
            """)
        }

        let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        check(
            frontAfter?.hasPrefix("com.literatureandlatte.scrivener") == true,
            "Scrivener came forward on its own, driven entirely by the explicit-app dispatch",
            frontAfter ?? "none")
    }

    // MARK: - The frontmost rung, on its own, with no corpus precondition

    /// Frontmost rung only: no corpus resolve; caller already has Scrivener in front.
    static func runFrontmostOnly(_ arguments: [String]) async {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted for this binary. Use ./scripts/dev.sh.")
            exit(1)
        }

        heading("the roster")
        let adapters = MaryAdapterCatalog.adapters()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: MaryAdapterCatalog.observers()),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        check(load.activated, "the packages loaded", "\(load.snapshot.records.count)")
        for issue in load.issues where issue.severity == .error {
            print("      ! \(issue.code): \(issue.message)")
        }

        let registrations = MaryRuntime.corpusRegistrations(from: load.snapshot)
        CorpusSupport.shared.reconcile(registrations)
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        AmbientApplicationBridge.install(profiles: profiles)

        heading("what is frontmost")
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front?.hasPrefix("com.literatureandlatte.scrivener") == true else {
            print("  ✗ Scrivener isn't frontmost (front: \(front ?? "none")). Bring it forward "
                + "yourself first — this mode never activates it — and run this again.")
            exit(1)
        }
        check(true, "Scrivener is frontmost", front ?? "")

        heading("dispatching type_at_cursor for real — NO explicit app")
        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let marker = value("--marker")
            ?? " [[MARY-PROBE-FRONTMOST-\(Int(Date().timeIntervalSince1970))]]"
        let typeOutcome = await runtime.dispatch(
            name: "type_at_cursor",
            argumentsJSON: #"{"text":"\#(marker)"}"#)
        check(typeOutcome.ok, "type_at_cursor dispatched without a refusal", typeOutcome.summary)
        if !typeOutcome.ok {
            print("""

              ✗ type_at_cursor refused. If the refusal text mentions "a text \
                cursor", place a real cursor in a Scrivener document's editor \
                pane (click into it) and run this again.
            """)
        }
    }
}

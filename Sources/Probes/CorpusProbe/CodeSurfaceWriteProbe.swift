//
//  CodeSurfaceWriteProbe.swift
//  CorpusProbe
//
//  WHAT: Disk-write path via real dispatch (replace_selection → CodeSurfaceWriter).
//  OUT:  CLI: mary-corpus-probe --dispatch-code-write [--replace-text|--expect-refusal]
//  PIN:  Operates on whatever Xcode has selected; scratch-file-first.
//

import ApplicationServices
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum CodeSurfaceWriteProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("--dispatch-code-write")
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

        let registrations = MaryRuntime.codeSurfaceRegistrations(from: load.snapshot)
        CodeSurfaceSupport.shared.reconcile(registrations)
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        AmbientApplicationBridge.install(profiles: profiles)

        heading("what is open")
        guard let registration = CodeSurfaceSupport.shared.registration(applicationID: "xcode"),
              let pid = CodeSurfaceSupport.pid(of: registration)
        else {
            print("  ✗ Xcode isn't running. Open it on a scratch Swift file and try again.")
            exit(1)
        }
        check(true, "Xcode is running", "pid \(pid)")

        let activation = await VerifiedActivation.bringForward(pid: pid, requireVisibleWindow: true)
        check(activation.succeeded, "Xcode came forward",
              activation.road.map(String.init(describing:))
                  ?? activation.reason(app: registration.displayName) ?? "refused")

        heading("the real lead")
        WorkspaceFocusTracker.shared.sample()
        let signal = WorkspaceFocusTracker.shared.signal()
        let leadApplicationID = signal.lead?.application
        check(leadApplicationID == "xcode",
              "the tracker's own frontmost read leads with Xcode", leadApplicationID ?? "none")

        let utterance = value("--utterance") ?? "replace what I've selected"
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: utterance, leadApplicationID: leadApplicationID, profiles: profiles))
        AmbientContextStore.shared.noteUtterance(utterance)
        AmbientContextStore.shared.noteRoute(route)
        check(route.leadPlace?.application == "xcode",
              "the route's lead place names Xcode", route.leadPlace?.token ?? "none")

        heading("what the model would actually be offered")
        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let offered = Set(runtime.schemas.map(\.name))
        check(offered.contains("replace_selection"), "replace_selection is in this turn's roster")
        guard offered.contains("replace_selection") else {
            for decision in runtime.abilityRosterTrace.decisions
            where decision.reference.invocationName == "replace_selection" {
                print("      trace: replace_selection → \(decision.disposition.rawValue): \(decision.reason)")
            }
            AmbientContextStore.shared.noteRoute(route)
            exit(1)
        }

        heading("before the write")
        let bufferBefore = await runtime.dispatch(name: "read_buffer", argumentsJSON: "{}")
        check(bufferBefore.ok, "read_buffer dispatched", bufferBefore.foundNothing ? "empty" : "ok")
        let selectionBefore = await runtime.dispatch(name: "read_selection", argumentsJSON: "{}")
        check(selectionBefore.ok, "read_selection dispatched")
        print("      LIVE BUFFER BEFORE (first 300):")
        print("      " + bufferBefore.summary.prefix(300).replacingOccurrences(of: "\n", with: "\n      "))
        print("      LIVE SELECTION BEFORE:")
        print("      " + selectionBefore.summary)
        if selectionBefore.foundNothing {
            print("""

              ✗ Nothing is selected in Xcode's front editor. Select some real \
                text (e.g. Cmd-A, or a real span) in a SCRATCH file — never a \
                tracked source file for the first pass — and run this again.
            """)
            AmbientContextStore.shared.noteRoute(route)
            exit(1)
        }

        // THE REFUSAL MODE — dispatches and asserts a refusal, for proving
        // the clean-buffer gate against a genuinely dirty buffer: type an
        // unsaved edit into Xcode by hand, then run this flag.
        if arguments.contains("--expect-refusal") {
            heading("dispatching replace_selection — expecting a refusal")
            let replacement = value("--replace-text") ?? "// mary probe: should never land"
            let outcome = await runtime.dispatch(
                name: "replace_selection",
                argumentsJSON: #"{"text":"\#(replacement.replacingOccurrences(of: "\"", with: "\\\""))"}"#)
            check(!outcome.ok, "replace_selection refused, as the dirty buffer requires",
                  outcome.summary)
            let bufferAfter = await runtime.dispatch(name: "read_buffer", argumentsJSON: "{}")
            check(bufferAfter.summary == bufferBefore.summary,
                  "and the live buffer is exactly what it was before the attempt")
            AmbientContextStore.shared.noteRoute(route)
            exit(failures == 0 ? 0 : 1)
        }

        heading("dispatching replace_selection for real")
        let replacement = value("--replace-text")
            ?? "// mary-corpus-probe --dispatch-code-write, \(Date())"
        let writeOutcome = await runtime.dispatch(
            name: "replace_selection",
            argumentsJSON: #"{"text":"\#(replacement.replacingOccurrences(of: "\"", with: "\\\""))"}"#)
        check(writeOutcome.ok, "replace_selection dispatched without a refusal", writeOutcome.summary)
        print("      \(writeOutcome.summary)")

        heading("after the write")
        // Poll until the live buffer shows the write (Xcode reload is async).
        var bufferAfter = SkillOutcome(ok: false, summary: "")
        for attempt in 1...6 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            bufferAfter = await runtime.dispatch(name: "read_buffer", argumentsJSON: "{}")
            if bufferAfter.ok, bufferAfter.summary.contains(replacement) { break }
            print("      (poll \(attempt)/6 — not yet reloaded)")
        }
        check(bufferAfter.ok, "read_buffer dispatched again")
        print("      LIVE BUFFER AFTER (first 300):")
        print("      " + bufferAfter.summary.prefix(300).replacingOccurrences(of: "\n", with: "\n      "))
        check(bufferAfter.summary.contains(replacement),
              "and Xcode's own live buffer reflects the write",
              "looked for: \(replacement.prefix(80))")
        check(bufferAfter.summary != bufferBefore.summary,
              "the buffer genuinely changed rather than reporting a stale read")

        AmbientContextStore.shared.noteRoute(route)
        exit(failures == 0 ? 0 : 1)
    }
}

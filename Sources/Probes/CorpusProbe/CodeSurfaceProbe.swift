//
//  CodeSurfaceProbe.swift
//  CorpusProbe
//
//  THE LIVE BUFFER AND SELECTION, DRIVEN THROUGH REAL DISPATCH — Step 3/4 of
//  the fluid-search plan ("why-does-mary-keep-mutable-rabbit.md"), for the
//  part `search_corpus`/`read_corpus_document` structurally cannot cover:
//  corpus reads come from disk, and an unsaved edit is not on disk yet.
//
//  LIVES IN THE CORPUS PROBE BINARY rather than a new one, on the same
//  reasoning `ProjectProbe.runDispatchCode` already established for this
//  file's sibling: this binary already builds the whole package graph,
//  brings Xcode forward through `VerifiedActivation`, samples the real
//  ambient lead through `WorkspaceFocusTracker`, and resolves a real route
//  through `AmbientEngine` — every step `--dispatch-code-surface` also
//  needs, none of it worth a second binary and a second copy of this
//  scaffolding.
//
//    mary-corpus-probe --dispatch-code-surface
//    mary-corpus-probe --dispatch-code-surface --utterance "what does this do"
//    mary-corpus-probe --dispatch-code-surface --debug-roles       ← role histogram of Xcode's window
//    mary-corpus-probe --dispatch-code-surface --expect-unsaved "marker text"
//                                                ← asserts the live buffer contains this exact
//                                                  string, for proving the unsaved-edit-tracking
//                                                  property against a manually typed marker
//
//  WHAT THIS PROVES THAT A DIRECT ADAPTER CALL CANNOT — the browsing-lane
//  lesson this whole branch keeps re-learning: that `read_buffer`/
//  `read_selection` are actually OFFERED to the model when Xcode leads a
//  turn, not just that `CodeSurfaceAX` can read an element. `coding.mary`'s
//  ability-level eligibility admits ANY utterance while `workspaceFamily ==
//  "coding"` (a bare arm, no intent classification required) — unlike
//  `writing.mary`'s tighter policy for its own corpus skills — so this is
//  expected to succeed for an ordinary coding question with no special
//  phrasing, and checks that rather than assuming it.
//

import ApplicationServices
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum CodeSurfaceProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("--dispatch-code-surface")
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
        check(registrations.contains { $0.applicationID == "xcode" },
              "xcode.mary declares a codeSurface",
              registrations.map(\.applicationID).joined(separator: ", "))
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        AmbientApplicationBridge.install(profiles: profiles)

        heading("what is open")
        guard let registration = CodeSurfaceSupport.shared.registration(applicationID: "xcode"),
              let pid = CodeSurfaceSupport.pid(of: registration)
        else {
            print("  ✗ Xcode isn't running. Open it on a real Swift file and try again.")
            exit(1)
        }
        check(true, "Xcode is running", "pid \(pid)")

        let activation = await VerifiedActivation.bringForward(pid: pid, requireVisibleWindow: true)
        check(activation.succeeded, "Xcode came forward",
              activation.road.map(String.init(describing:))
                  ?? activation.reason(app: registration.displayName) ?? "refused")

        // ROLE HISTOGRAM, ON DEMAND. This is how the descent-budget bug was
        // actually found live: a real Xcode window walked at 400 nodes
        // exhausted its breadth-first queue inside the project navigator (83
        // `AXRow`/`AXCell` pairs, 84 `AXImage` icons) before ever reaching
        // the single `AXTextArea` sitting past it, and `CodeSurfaceAX`
        // reported "no source file open" against a window visibly showing
        // one. Kept here rather than deleted after the fix, because the next
        // application this lane grows to may need the same measurement.
        if arguments.contains("--debug-roles") {
            let application = AXUIElementCreateApplication(pid)
            let windows = AX.children(application, kAXWindowsAttribute)
            print("      DEBUG windows: \(windows.count)")
            for window in windows {
                let title = AX.string(window, kAXTitleAttribute) ?? "—"
                print("      DEBUG window title=\(title)")
                var byRole: [String: Int] = [:]
                AXTreeWalker.walk(from: window, budget: .standard) { element, _ in
                    let role = AX.string(element, kAXRoleAttribute) ?? "?"
                    byRole[role, default: 0] += 1
                }
                for (role, count) in byRole.sorted(by: { $0.value > $1.value }) {
                    print("      DEBUG   \(role): \(count)")
                }
            }
        }

        heading("the real lead")
        WorkspaceFocusTracker.shared.sample()
        let signal = WorkspaceFocusTracker.shared.signal()
        let leadApplicationID = signal.lead?.application
        check(leadApplicationID == "xcode",
              "the tracker's own frontmost read leads with Xcode",
              leadApplicationID ?? "none")

        let utterance = value("--utterance") ?? "what does this function do"
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: utterance,
            leadApplicationID: leadApplicationID,
            profiles: profiles))
        AmbientContextStore.shared.noteUtterance(utterance)
        AmbientContextStore.shared.noteRoute(route)
        check(route.leadPlace?.application == "xcode",
              "the route's lead place names Xcode",
              route.leadPlace?.token ?? "none")
        print("      workspace family: \(route.leadPlace?.ability?.rawValue ?? "none")")

        heading("what the model would actually be offered")
        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let offered = Set(runtime.schemas.map(\.name))
        // THE ABILITY-CONFLICT REGRESSION, LIVE. `build_project` is coding's
        // own chord Skill, unrelated to the code-surface lane; it and
        // `search_corpus` (writing's corpus Skill) must BOTH be reachable at
        // once now — see `CodingDisciplineTests
        // .codingStaysActiveAlongsideWritingWhenXcodeHasAProjectCorpus` for
        // the mechanism this is proving live rather than synthetically.
        check(offered.contains("build_project"),
              "coding's own build_project also survives the ability conflict")
        check(offered.contains("search_corpus"),
              "writing's search_corpus is admitted too — a tie, not a loss")
        var allOffered = true
        for wanted in ["read_buffer", "read_selection"] {
            let present = offered.contains(wanted)
            allOffered = allOffered && present
            check(present, "\(wanted) is in this turn's roster")
        }
        guard allOffered else {
            print("""

              ✗ read_buffer/read_selection did not project for this turn. If \
                coding.mary's ability-level eligibility narrowed since this was \
                written, try --utterance with a phrasing that matches one of \
                its admitting arms.
            """)
            for decision in runtime.abilityRosterTrace.decisions
            where decision.reference.invocationName == "read_buffer"
                || decision.reference.invocationName == "read_selection" {
                print("      trace: \(decision.reference.invocationName) → "
                    + "\(decision.disposition.rawValue): \(decision.reason)")
            }
            AmbientContextStore.shared.noteRoute(route)
            exit(1)
        }

        heading("dispatching read_buffer for real")
        let bufferOutcome = await runtime.dispatch(name: "read_buffer", argumentsJSON: "{}")
        check(bufferOutcome.ok, "read_buffer dispatched without a refusal")
        check(!bufferOutcome.foundNothing, "and a real source file answered")
        print("      \(bufferOutcome.summary.prefix(400).replacingOccurrences(of: "\n", with: "\n      "))…")
        // REAL SOURCE, not a decode artefact — the same check
        // `--dispatch-code` uses for `read_corpus_document`.
        check(
            bufferOutcome.summary.contains("func ") || bufferOutcome.summary.contains("struct ")
                || bufferOutcome.summary.contains("import "),
            "and it reads as real Swift")
        if let marker = value("--expect-unsaved") {
            check(bufferOutcome.summary.contains(marker),
                  "and it contains the live unsaved marker", marker)
        }

        heading("dispatching read_selection for real")
        let selectionOutcome = await runtime.dispatch(name: "read_selection", argumentsJSON: "{}")
        check(selectionOutcome.ok, "read_selection dispatched without a refusal")
        print("      \(selectionOutcome.summary)")
        if selectionOutcome.foundNothing {
            print("""

              ⚠︎ Nothing was selected in Xcode when this ran — that is a valid \
                answer, not a failure, but it does not prove the SELECTION \
                path. Highlight a real, non-trivial span of text in Xcode's \
                editor and run this again with the same command to confirm \
                the [[…]]-marked text above matches it exactly.
            """)
        }

        AmbientContextStore.shared.noteRoute(route)
    }
}

//
//  CodeSurfaceProbe.swift
//  CorpusProbe
//
//  WHAT: Live Xcode buffer/selection via real AbilityRuntime.dispatch.
//  OUT:  CLI: mary-corpus-probe --dispatch-code-surface […]
//  PIN:  Corpus reads are disk; unsaved edits are not. This is that gap.
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

        // list_declarations reads patterns from CorpusSupport, not CodeSurfaceSupport.
        CorpusSupport.shared.reconcile(MaryRuntime.corpusRegistrations(from: load.snapshot))
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

        // Role histogram: descent budget used to exhaust in the navigator before AXTextArea.
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

        // Optional restored range (`--caret-at`/`--select`). Restored in defer; not an edit.
        var restoreRange: (() -> Void)?
        defer { restoreRange?() }
        if let requested = value("--caret-at"), let offset = Int(requested) {
            let length = value("--select").flatMap(Int.init) ?? 0
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 2.0)
            if let focusedWindow = AX.element(application, kAXFocusedWindowAttribute),
               let editor = CodeSurfaceEditorCache.editor(
                pid: pid, window: focusedWindow, registration: registration) {
                let original = CodeSurfaceAX.selectedRange(of: editor)
                func setRange(_ range: Range<Int>) {
                    var cfRange = CFRange(
                        location: range.lowerBound, length: range.count)
                    guard let value = withUnsafePointer(
                        to: &cfRange, { AXValueCreate(.cfRange, $0) })
                    else { return }
                    AXUIElementSetAttributeValue(
                        editor, kAXSelectedTextRangeAttribute as CFString, value)
                }
                setRange(offset..<(offset + max(0, length)))
                restoreRange = { if let original { setRange(original) } }
                check(true,
                      "the editor's range was set for this run (restored on exit)",
                      length > 0
                        ? "\(offset)…\(offset + length) selected"
                        : "caret at \(offset)")
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
        // Live: build_project and search_corpus must both be reachable (coding+writing tie).
        check(offered.contains("build_project"),
              "coding's own build_project also survives the ability conflict")
        check(offered.contains("search_corpus"),
              "writing's search_corpus is admitted too — a tie, not a loss")
        var allOffered = true
        for wanted in ["read_buffer", "read_selection", "list_declarations"] {
            let present = offered.contains(wanted)
            allOffered = allOffered && present
            check(present, "\(wanted) is in this turn's roster")
        }
        guard allOffered else {
            print("""

              ✗ read_buffer/read_selection/list_declarations did not project for this turn. If \
                coding.mary's ability-level eligibility narrowed since this was \
                written, try --utterance with a phrasing that matches one of \
                its admitting arms.
            """)
            for decision in runtime.abilityRosterTrace.decisions
            where decision.reference.invocationName == "read_buffer"
                || decision.reference.invocationName == "read_selection"
                || decision.reference.invocationName == "list_declarations" {
                print("      trace: \(decision.reference.invocationName) → "
                    + "\(decision.disposition.rawValue): \(decision.reason)")
            }
            AmbientContextStore.shared.noteRoute(route)
            exit(1)
        }

        // Print whether AX first-editor window and focused window agree.
        if arguments.contains("--debug-windows") {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 2.0)
            let windows = AX.children(application, kAXWindowsAttribute)
            let focused = AX.element(application, kAXFocusedWindowAttribute)
            print("      DEBUG windows: \(windows.count)")
            for (offset, window) in windows.enumerated() {
                let title = AX.string(window, kAXTitleAttribute) ?? "—"
                let isFocused = focused.map { CFEqual($0, window) } ?? false
                print("      DEBUG   [\(offset)] \(isFocused ? "FOCUSED " : "")\(title)")
            }
        }

        // End-to-end dispatch latency via CodeSurfaceEditorCache.frontSurface.
        func timed(_ label: String, _ body: () async -> SkillOutcome) async -> SkillOutcome {
            let started = Date()
            let outcome = await body()
            print(String(format: "      ⏱  %@: %.1f ms", label, Date().timeIntervalSince(started) * 1000))
            return outcome
        }

        heading("dispatching read_buffer for real")
        // Invalidate first so the cold number is not a reused cache walk.
        CodeSurfaceEditorCache.invalidate()
        let bufferOutcome = await timed("read_buffer") {
            await runtime.dispatch(name: "read_buffer", argumentsJSON: "{}")
        }
        // Warm repeat — the usual session path.
        _ = await timed("read_buffer (warm)") {
            await runtime.dispatch(name: "read_buffer", argumentsJSON: "{}")
        }
        check(bufferOutcome.ok, "read_buffer dispatched without a refusal")
        check(!bufferOutcome.foundNothing, "and a real source file answered")
        print("      \(bufferOutcome.summary.prefix(400).replacingOccurrences(of: "\n", with: "\n      "))…")
        // Real Swift source, same check as `--dispatch-code`.
        check(
            bufferOutcome.summary.contains("func ") || bufferOutcome.summary.contains("struct ")
                || bufferOutcome.summary.contains("import "),
            "and it reads as real Swift")
        if let marker = value("--expect-unsaved") {
            check(bufferOutcome.summary.contains(marker),
                  "and it contains the live unsaved marker", marker)
        }

        heading("dispatching read_selection for real")
        let selectionOutcome = await timed("read_selection") {
            await runtime.dispatch(name: "read_selection", argumentsJSON: "{}")
        }
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

        heading("dispatching list_declarations for real")
        let declarationsOutcome = await timed("list_declarations") {
            await runtime.dispatch(name: "list_declarations", argumentsJSON: "{}")
        }
        check(declarationsOutcome.ok, "list_declarations dispatched without a refusal")
        check(!declarationsOutcome.foundNothing, "and real declarations came back")
        print("      \(declarationsOutcome.summary.replacingOccurrences(of: "\n", with: "\n      "))")
        check(declarationsOutcome.summary.contains(" — line "),
              "and each declaration reports an approximate line")
        // Functions as well as types; printed list is the evidence.

        // Surface-locate cost only; skip when a highlight would make this a real write.
        heading("replace_selection's surface cost")
        if selectionOutcome.foundNothing {
            let replaceOutcome = await timed("replace_selection (no-op, nothing selected)") {
                await runtime.dispatch(
                    name: "replace_selection",
                    argumentsJSON: #"{"text":"// probe: never written, nothing is selected"}"#)
            }
            check(replaceOutcome.foundNothing,
                  "and it stopped at \"nothing is selected\" without writing",
                  replaceOutcome.summary)
        } else if let replacement = value("--replace-selection") {
            // Real write only when `--replace-selection` is named; re-read disk after.
            let replaceOutcome = await timed("replace_selection (REAL WRITE)") {
                await runtime.dispatch(
                    name: "replace_selection",
                    argumentsJSON: String(
                        data: try! JSONSerialization.data(
                            withJSONObject: ["text": replacement]), encoding: .utf8)!)
            }
            check(replaceOutcome.ok, "replace_selection reported success",
                  replaceOutcome.summary)
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 2.0)
            if let surface = CodeSurfaceEditorCache.frontSurface(
                pid: pid, registration: registration),
               // documentKey is a file URL; resolve independently of the writer.
               let url = URL(string: surface.documentKey),
               url.isFileURL,
               let onDisk = try? String(contentsOf: url, encoding: .utf8) {
                check(onDisk.contains(replacement),
                      "and the replacement is ON DISK when the file is re-read",
                      url.path)
            } else {
                check(false, "could not re-read the file to confirm the write")
            }
        } else {
            print("""

              ⚠︎ Something IS selected, so replace_selection was NOT dispatched \
                — it would have written to disk. Run this again with nothing \
                highlighted to time its surface lookup, or pass \
                --replace-selection "text" to drive the real write.
            """)
        }

        // code-selection Interaction: registry resolves the schema; live Xcode packet passes mint guards.
        heading("the code-selection Interaction")
        let codeSelection = load.snapshot.interactionSchema(id: .codeSelection)
        check(codeSelection != nil,
              "the live registry resolves interaction.code-selection",
              codeSelection?.valueType.rawValue ?? "undeclared")

        let bundleID = registration.bundleIdentifiers.first ?? "com.apple.dt.Xcode"
        let sample = AXSelectionReader.sourceSelectionSample(pid: pid)
        SelectionHandoffPublisher.captureOutcome(
            sample,
            ambient: AmbientContextStore.shared,
            place: .application(registration.applicationID),
            applicationID: bundleID,
            subject: registration.displayName,
            channel: .applicationHandoff)
        if let handoff = AmbientContextStore.shared.liveSelectionHandoff() {
            check(handoff.place.focus == .coding,
                  "the live selection's place codes",
                  handoff.place.focus.map(String.init(describing:)) ?? "none")
            check(handoff.interactionReference.schemaID == .codeSelection,
                  "and the packet names interaction.code-selection",
                  handoff.interactionReference.schemaID.rawValue)
            if let schema = codeSelection {
                check(schema.requiredScope.contains(handoff.scope.resolution),
                      "the schema accepts this packet's source resolution",
                      handoff.scope.resolution.rawValue)
                check(handoff.scope.applicationID != nil,
                      "and its sourceOwned ownership is satisfied",
                      handoff.scope.applicationID ?? "none")
                check(handoff.isFresh(), "and it is fresh")
                // The channel `bridgeSelection` computes for THIS packet,
                // resolved the same way it resolves it.
                let channel: String
                switch (handoff.sourceEvidence, handoff.payloadRecovery) {
                case (_, .some(.applicationBodyRange)):
                    channel = "application-body-range-hydration"
                case (_, .some(.applicationCopy)):
                    channel = "application-copy-probe"
                case (.documentAtomic, nil): channel = "code-buffer-selection"
                case (.discoveredDescendant, nil):
                    channel = "workspace-descendant-discovery"
                default: channel = "focused-accessibility-selection"
                }
                check(schema.evidence.contains { $0.channel == channel },
                      "and declares this packet's evidence channel", channel)
            }
            print("      selected: \(handoff.text.prefix(160))")
        } else {
            print("""

              ⚠︎ Nothing was selected in Xcode when this ran — the schema \
                half above still holds, but the MINTING half is unproven. \
                Highlight a real span in Xcode's editor and run this again.
            """)
        }

        // Standing cursor scope is in the ambient store before any Skill call.
        heading("the standing cursor scope, with no tool call")
        let cursorPlace = AmbientPlace.application(registration.applicationID)
        AmbientContextStore.shared.forget(key: AmbientKey(place: cursorPlace, slot: .cursor))

        // Live cache vs full editor walk; cache pays the walk once per window.
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 2.0)
        if let focusedWindow = AX.element(application, kAXFocusedWindowAttribute) {
            var coldMs: [Double] = []
            for _ in 0..<3 {
                CodeSurfaceEditorCache.invalidate()
                let started = Date()
                _ = CodeSurfaceAX.editor(in: focusedWindow, registration: registration)
                coldMs.append(Date().timeIntervalSince(started) * 1000)
            }
            CodeSurfaceEditorCache.invalidate()
            CodeSurfaceEditorCache.resetWalkCount()
            let primeStarted = Date()
            _ = CodeSurfaceEditorCache.editor(
                pid: pid, window: focusedWindow, registration: registration)
            let primeMs = Date().timeIntervalSince(primeStarted) * 1000
            var warmMs: [Double] = []
            for _ in 0..<20 {
                let started = Date()
                _ = CodeSurfaceEditorCache.editor(
                    pid: pid, window: focusedWindow, registration: registration)
                warmMs.append(Date().timeIntervalSince(started) * 1000)
            }
            func stamp(_ values: [Double]) -> String {
                let mean = values.reduce(0, +) / Double(max(1, values.count))
                return String(format: "mean %.2f ms over %d", mean, values.count)
            }
            print("      uncached walk:  \(stamp(coldMs))")
            print("      cache prime:    " + String(format: "%.2f ms", primeMs))
            print("      cached lookup:  \(stamp(warmMs))")
            check(CodeSurfaceEditorCache.walkCount == 1,
                  "21 lookups of one unchanged window cost exactly one walk",
                  "\(CodeSurfaceEditorCache.walkCount)")
            let warmMean = warmMs.reduce(0, +) / Double(max(1, warmMs.count))
            let coldMean = coldMs.reduce(0, +) / Double(max(1, coldMs.count))
            check(warmMean * 10 < coldMean,
                  "a cached lookup is more than an order of magnitude cheaper",
                  String(format: "%.2f ms vs %.2f ms", warmMean, coldMean))
        }

        // THE POLL ITSELF, exactly as the turn preparer calls it.
        let pollStarted = Date()
        CodeSurfaceObserver.shared.pollOnce()
        print(String(format: "      one poll: %.2f ms",
                     Date().timeIntervalSince(pollStarted) * 1000))
        let cursor = AmbientContextStore.shared.fact(
            world: cursorPlace.world, application: cursorPlace.application, slot: .cursor)
        if let cursor {
            check(true, "a standing cursor fact is held", cursor.subject ?? "—")
            check(cursor.anchor == .caret, "and it is anchored on the caret",
                  cursor.anchor.map(String.init(describing:)) ?? "none")
            check(cursor.content.hasPrefix("Cursor scope: ")
                    || cursor.content.hasPrefix("Cursor at line "),
                  "and it leads with a measured scope line",
                  String(cursor.content.prefix(80)))
            check(cursor.content.count
                    <= registration.budgets.ambientExcerptCharacters + 200,
                  "and it respects the declared ambientExcerptCharacters budget",
                  "\(cursor.content.count) chars, budget "
                    + "\(registration.budgets.ambientExcerptCharacters)")
            print("      ── the block the prompt would carry ──")
            print("      " + cursor.block(limit: 2000)
                    .replacingOccurrences(of: "\n", with: "\n      "))
        } else if selectionOutcome.foundNothing {
            print("""

              ⚠︎ No cursor fact, and nothing was selected either — so this is \
                the "no source file open" state rather than the stand-down. \
                Click into a real function and run this again.
            """)
        }

        // Cursor lane stands down while a selection stands; asserted both ways.
        if selectionOutcome.foundNothing {
            check(cursor != nil,
                  "with nothing selected, the cursor lane holds the ground")
        } else {
            check(cursor == nil,
                  "with a live highlight, the cursor lane stands down for the "
                    + "selection lane",
                  cursor == nil ? "no cursor fact" : "BOTH published")
        }

        // Xcode still refuses type_at_cursor (codeSurface / .coding, not prose).
        heading("dispatching type_at_cursor for real — must still refuse")
        let typeOutcome = await runtime.dispatch(
            name: "type_at_cursor", argumentsJSON: #"{"text":"should never land"}"#)
        check(!typeOutcome.ok, "type_at_cursor is still refused for Xcode", typeOutcome.summary)

        AmbientContextStore.shared.noteRoute(route)
    }
}

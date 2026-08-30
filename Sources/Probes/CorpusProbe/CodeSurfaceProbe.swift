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
//    mary-corpus-probe --dispatch-code-surface --caret-at 4200 [--select 120]
//                                                ← sets the editor's range for this run and
//                                                  RESTORES the user's own before exiting. The
//                                                  only way to prove, on demand, both a
//                                                  particular scope chain and the standing-cursor
//                                                  lane standing down under a live highlight.
//    mary-corpus-probe --dispatch-code-surface --debug-windows
//                                                ← which window kAXWindows[0] and
//                                                  kAXFocusedWindow each name, since the
//                                                  handlers now ask the second where they
//                                                  used to walk from the first
//    mary-corpus-probe --dispatch-code-surface --caret-at 100 --select 40 \
//                      --replace-selection "// new text"
//                                                ← THE ONE ARGUMENT THAT WRITES. Dispatches
//                                                  replace_selection for real and then
//                                                  RE-READS the file from disk to prove the
//                                                  bytes landed. Use a scratch file.
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

        // list_declarations READS ITS PATTERNS FROM `CorpusSupport`, NOT
        // `CodeSurfaceSupport` — see `CodeSurfaceAdapter.listDeclarations`'s
        // own header. The app's real install path (`MaryRuntime
        // +BrainInstall.installBrainConfiguration`) reconciles both
        // registries from the same snapshot; this probe drove only the
        // `codeSurface` half, so `list_declarations` dispatched real but
        // always answered "no declared outline patterns" here — not because
        // the Skill or the shipped `xcode.mary` package were broken, but
        // because this probe process's `CorpusSupport.shared` was never
        // told the package existed. Mirrored from `main.swift`'s own
        // `CorpusSupport.shared.reconcile` call, which this early-exit path
        // (line 44 below) never reaches.
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

        // AN OPTIONAL, RESTORED RANGE. Two claims below depend on where the
        // caret is and whether anything is highlighted, which makes them the
        // only ones here that cannot be proved on demand against a real
        // editor without asking the editor to put its insertion point
        // somewhere: the scope line's two-level "struct X → func y" shape,
        // and the standing-cursor lane STANDING DOWN while a highlight is
        // live. `--caret-at`/`--select` do exactly that and nothing else —
        // record the live range, set a new one, and put the original back in
        // a `defer` before this function returns. No text is read, written,
        // or typed, and no synthetic keystroke is sent: `coding.mary`'s
        // "never type into a code surface" guardrail is untouched, because
        // moving an insertion point is not an edit.
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

        // WHICH WINDOW EACH PATH IS TALKING ABOUT. `CodeSurfaceAX.frontSurface`
        // takes `kAXWindows`' FIRST entry that holds an editor;
        // `CodeSurfaceEditorCache.frontSurface` takes `kAXFocusedWindow`. They
        // are the same window in the ordinary case and this prints whether they
        // actually are, live, rather than leaving it asserted in a comment.
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

        // PER-HANDLER LATENCY, MEASURED THROUGH REAL DISPATCH. Every one of
        // these used to pay `CodeSurfaceAX.surfaces`' all-windows walk on every
        // call; they now go through `CodeSurfaceEditorCache.frontSurface`. The
        // numbers printed here are the whole reason that change was made, and
        // they are taken end-to-end through `AbilityRuntime.dispatch` rather
        // than around the adapter, so they include everything a real turn pays.
        func timed(_ label: String, _ body: () async -> SkillOutcome) async -> SkillOutcome {
            let started = Date()
            let outcome = await body()
            print(String(format: "      ⏱  %@: %.1f ms", label, Date().timeIntervalSince(started) * 1000))
            return outcome
        }

        heading("dispatching read_buffer for real")
        // COLD ON PURPOSE for the first number below: `--caret-at` above and
        // the observer both prime the same one-entry cache, and a "first call"
        // timing that silently reused their walk would flatter the change this
        // section exists to measure.
        CodeSurfaceEditorCache.invalidate()
        let bufferOutcome = await timed("read_buffer") {
            await runtime.dispatch(name: "read_buffer", argumentsJSON: "{}")
        }
        // AND AGAIN, warm — the first call of the process pays a cache prime
        // the second does not, and a caller in a real session is almost always
        // the second kind.
        _ = await timed("read_buffer (warm)") {
            await runtime.dispatch(name: "read_buffer", argumentsJSON: "{}")
        }
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
        // FUNCTIONS AMONG THEM, NOT ONLY TYPES — the property that makes
        // this the `func` pattern's live proof and not just `declarations`'
        // pre-existing type-only one. The printed list above is the actual
        // evidence; cross-check it by eye against the open file's real
        // `func` names.

        // replace_selection'S OWN SURFACE COST, AND ONLY THAT. This is the one
        // handler that writes, so it is never dispatched here for a
        // measurement while something is selected — the number wanted is what
        // it spends LOCATING the surface, which is the only part
        // `[Corpus AC]` changed, and that part runs identically before the
        // "nothing is selected" early return. Skipped, with a word, whenever a
        // live highlight would make the call a real edit.
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
            // THE WRITE, FOR REAL, AND ONLY WHEN ASKED BY NAME. `--replace-
            // selection` is the one argument in this probe that changes a file
            // on disk, so it is never implied by anything else and never runs
            // against whatever happened to be highlighted — pair it with
            // `--caret-at`/`--select` on a scratch file.
            //
            // AND THE FILE IS RE-READ AFTERWARDS rather than the outcome
            // believed. This branch's standing discipline: a writer that
            // reports success has reported its own opinion, and the only
            // evidence that bytes landed is the bytes.
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
               // `documentKey` IS A `file://` URL STRING — measured, and the
               // reason `CodeSurfaceWriter.fileURL` exists. Resolved here
               // rather than through that (internal) helper so this check
               // reaches disk by its OWN route, which is what makes it
               // evidence about the write instead of a second reading of the
               // writer's own opinion.
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

        // THE INTERACTION THAT NEVER MINTED. `SchemaSignalRuntime
        // .bridgeSelection` has always computed `interaction.code-selection`
        // for a selection whose place codes — and until now no package
        // declared that Interaction, so the registry lookup failed, nil came
        // back, and a real Xcode highlight became no routable fact at all.
        //
        // WHAT THIS CAN AND CANNOT SEE FROM OUT HERE, honestly: the bridge
        // itself (`snapshotForTurn(registry:ambientSelection:)`) and
        // `SchemaSignalTurnContext` are MaryBrain-internal, so this binary
        // cannot read `abilityRoutingContext().interactions` directly — the
        // exact boundary `[Corpus N]` hit and documented. What it CAN do is
        // prove the two things that decide the outcome, against real live
        // data: that the shipped registry now resolves the schema, and that
        // the genuine Xcode selection packet satisfies every guard
        // `bridgeSelection` applies before minting. The turn-level proof is
        // `CodeSelectionInteractionTests` (the real bridge, @testable) and a
        // real `--probe-chat` turn.
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

        // THE STANDING CURSOR SCOPE — Bonnie's "Cursor scope: struct X → var
        // body" parity, and the one property it exists for: the fact is in
        // the ambient store BEFORE the model is asked anything, so a turn can
        // be grounded with NO tool call. Everything above this heading
        // dispatched a Skill to get its answer; nothing below one does.
        heading("the standing cursor scope, with no tool call")
        let cursorPlace = AmbientPlace.application(registration.applicationID)
        AmbientContextStore.shared.forget(key: AmbientKey(place: cursorPlace, slot: .cursor))

        // THE MEASUREMENT THE CACHE EXISTS FOR, taken live rather than
        // reasoned about. `CodeSurfaceAX.editor` is the ~330 ms bounded walk
        // every code-surface read used to pay per call; the cache pays it
        // once per window and re-proves the entry with one attribute read.
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

        // THE STAND-DOWN, WHICH IS THE OTHER HALF OF THE PROPERTY. A live
        // highlight belongs to the selection lane — its handoff, its
        // Interaction, the `.selection` fact only `recordSelection` may
        // write. Two claims about "where the user is" in one prompt under two
        // different authorities is the hazard the store's ordering exists to
        // close, so this lane publishes NOTHING while a selection stands.
        // Asserted in both directions, from the same run's own evidence.
        if selectionOutcome.foundNothing {
            check(cursor != nil,
                  "with nothing selected, the cursor lane holds the ground")
        } else {
            check(cursor == nil,
                  "with a live highlight, the cursor lane stands down for the "
                    + "selection lane",
                  cursor == nil ? "no cursor fact" : "BOTH published")
        }

        // THE NEGATIVE THIS FIX MUST NOT DISTURB — "why-does-mary-keep-
        // mutable-rabbit.md"'s Step 3: Xcode's `type_at_cursor` refusal is
        // BY DESIGN ("Never type prose into a code surface" — `xcode.mary`
        // declares `codeSurface`, not `proseSurface`, and its `focus` is
        // `.coding`). `PluginCompiler.perception`'s new `corpus`/
        // `mediaSurface` channels only ever widen HOW `hasEyes` is earned;
        // `isKnownProseEditor`'s OTHER half — `registration.place.focus ==
        // .writing` — is untouched, and Xcode's focus is `.coding` regardless
        // of `hasEyes`. Dispatched for real, not assumed, so a future change
        // to that focus projection would fail here instead of silently
        // starting to type into source files.
        heading("dispatching type_at_cursor for real — must still refuse")
        let typeOutcome = await runtime.dispatch(
            name: "type_at_cursor", argumentsJSON: #"{"text":"should never land"}"#)
        check(!typeOutcome.ok, "type_at_cursor is still refused for Xcode", typeOutcome.summary)

        AmbientContextStore.shared.noteRoute(route)
    }
}

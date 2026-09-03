//
//  ProjectProbe.swift
//  CorpusProbe
//
//  WHAT: Project-corpus lane against a real manuscript (not a synthetic manifest).
//  OUT:  CLI: mary-corpus-probe project --project … [--read|--live|--dispatch|--dispatch-code]
//

import ApplicationServices
import Foundation
import MaryAmbient
import MaryBrain
import MaryComputerUse
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum ProjectProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("project")
    }

    /// Whole chain: shipped packages, roster, and the project AXDocument actually has open.
    static func runLive() async {
        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted for this binary. Use ./scripts/dev.sh.")
            exit(1)
        }

        let adapters = MaryAdapterCatalog.adapters()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: MaryAdapterCatalog.observers()),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        print("▸ the roster")
        print("  packages    \(load.snapshot.records.count) loaded"
            + (load.activated ? "" : "  ⚠︎ NOT ACTIVATED"))
        for issue in load.issues where issue.severity == .error {
            print("  ! \(issue.code): \(issue.message)")
        }

        let registrations = MaryRuntime.corpusRegistrations(from: load.snapshot)
        CorpusSupport.shared.reconcile(registrations)
        print("  corpora     \(registrations.map(\.applicationID).joined(separator: ", "))")
        let projects = ProjectCorpusSupport.all()
        print("  projects    "
            + (projects.isEmpty
                ? "⚠︎ NONE — no corpus declares a structure"
                : projects.map(\.applicationID).joined(separator: ", ")))

        // Skills the model would see. Blocked install = lane does not exist to the model.
        let corpusSkills = load.snapshot.skills.filter {
            $0.skill.id.rawValue.contains("corpus")
        }
        for skill in corpusSkills.sorted(by: { $0.skill.id.rawValue < $1.skill.id.rawValue }) {
            let mark = skill.availability.readiness == .blocked ? "✗" : "✓"
            print("  \(mark) \(skill.skill.id.rawValue)  \(skill.availability.readiness)"
                + (skill.availability.reasons.isEmpty
                    ? "" : "  — \(skill.availability.reasons.joined(separator: " "))"))
        }

        print("\n▸ what is open")
        switch ProjectCorpusSupport.resolve(nil) {
        case .failure(let refusal):
            print("  ✗ \(refusal.spoken)")
        case .success(let corpus):
            print("  project     \(corpus.name)  (\(corpus.registration.displayName))")
            print("  root        \(corpus.projectRoot.path)")
            print("  editable    \(ProjectCorpusSupport.isOpenForEditing(corpus))")
            switch ProjectCorpusReader.outline(
                projectRoot: corpus.projectRoot, structure: corpus.structure) {
            case .failure(let failure): print("  ✗ \(failure.spoken)")
            case .success(let items):
                let flat = items.flatMap(\.flattened)
                print("  outline     \(flat.count) items · "
                    + "\(flat.filter(\.isContainer).count) containers")
            }
        }
    }

    /// Real AbilityRuntime.dispatch. Reachable when Scrivener leads; refused otherwise.
    /// Lead is sampled via WorkspaceFocusTracker (not asserted).
    static func runDispatch(_ arguments: [String]) async {
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

        heading("what is open")
        guard case .success(let corpus) = ProjectCorpusSupport.resolve(nil) else {
            print("  ✗ no project is open. Open Scrivener on a real manuscript and try again.")
            exit(1)
        }
        check(true, "a project resolved off AXDocument", corpus.name)

        // Bring forward, verified — lead must be earned, not assumed from the terminal.
        let activation = await VerifiedActivation.bringForward(
            pid: corpus.processIdentifier, requireVisibleWindow: true)
        check(activation.succeeded, "Scrivener came forward",
              activation.road.map(String.init(describing:))
                  ?? activation.reason(app: corpus.registration.displayName) ?? "refused")

        heading("the real lead")
        WorkspaceFocusTracker.shared.sample()
        let signal = WorkspaceFocusTracker.shared.signal()
        let leadApplicationID = signal.lead?.application
        check(leadApplicationID == corpus.registration.applicationID,
              "the tracker's own frontmost read leads with the corpus's application",
              leadApplicationID ?? "none")

        let query = value("--query") ?? "comet"
        let utterance = "find where the manuscript mentions \(query)"
        let route = AmbientEngine.resolve(AmbientEngine.Inputs.live(
            utterance: utterance,
            signal: signal,
            profiles: profiles))
        AmbientContextStore.shared.noteUtterance(utterance)
        AmbientContextStore.shared.noteRoute(route)
        check(route.leadPlace?.application == corpus.registration.applicationID,
              "the route's lead place names the corpus's application",
              route.leadPlace?.token ?? "none")
        check(route.leadPlace?.ability?.rawValue == "writing",
              "and the place registers a writing discipline",
              route.leadPlace?.ability?.rawValue ?? "none")

        heading("what the model would actually be offered")
        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let offered = Set(runtime.schemas.map(\.name))
        for wanted in [
            "search_corpus", "read_corpus_outline", "read_corpus_document", "corpus_progress",
        ] {
            check(offered.contains(wanted), "\(wanted) is in this turn's roster")
        }

        heading("dispatching search_corpus for real")
        let searchOutcome = await runtime.dispatch(
            name: "search_corpus",
            argumentsJSON: #"{"query":"\#(query)"}"#)
        check(searchOutcome.ok, "search_corpus dispatched without a refusal")
        check(!searchOutcome.foundNothing, "and it found the word in a real document",
              "query \"\(query)\"")
        print("      \(searchOutcome.summary.replacingOccurrences(of: "\n", with: "\n      "))")

        heading("dispatching read_corpus_outline and read_corpus_document for real")
        let outlineOutcome = await runtime.dispatch(
            name: "read_corpus_outline", argumentsJSON: "{}")
        check(outlineOutcome.ok, "read_corpus_outline dispatched")
        print("      \(outlineOutcome.summary.prefix(160))…")

        // Unique title ("Novel Format"); repeated "Section 1.1" is a correct refusal.
        let firstDocument = value("--read") ?? "Novel Format"
        let documentOutcome = await runtime.dispatch(
            name: "read_corpus_document",
            argumentsJSON: #"{"document":"\#(firstDocument)"}"#)
        check(documentOutcome.ok, "read_corpus_document dispatched", firstDocument)
        print("      \(documentOutcome.summary.prefix(160))…")

        heading("the negative: no writing lead, offered to nobody")
        // Fresh runtime offer ledger; this turn's projection, not leftover grace.
        let neutralRoute = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: "what's the weather like", profiles: profiles))
        AmbientContextStore.shared.noteRoute(neutralRoute)
        check(neutralRoute.leadPlace == nil, "this turn carries no application lead")
        let neutralRuntime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let neutralOffered = Set(neutralRuntime.schemas.map(\.name))
        check(!neutralOffered.contains("search_corpus"),
              "search_corpus is NOT offered without a writing lead")
        let neutralOutcome = await neutralRuntime.dispatch(
            name: "search_corpus", argumentsJSON: #"{"query":"\#(query)"}"#)
        check(!neutralOutcome.ok, "and calling it anyway is refused", neutralOutcome.summary)

        // RESTORE THE REAL LEAD before this process exits, so nothing else
        // sharing `AmbientContextStore.shared` in-process reads a stale
        // "nothing is happening" route on the way out.
        AmbientContextStore.shared.noteRoute(route)
    }

    /// Real dispatch against Xcode (`fileSystemTree`). AXDocument is the active file; climb projectMarkers.
    /// Writing Skills still need compose/revise or a text-selection — coding family alone is not enough.
    static func runDispatchCode(_ arguments: [String]) async {
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

        heading("what is open")
        // NAMED BY APPLICATION, not `ProjectCorpusSupport.resolve(nil)` —
        // that call picks among every open corpus by PROJECT name, and with
        // Scrivener possibly open too this probe needs specifically Xcode's.
        guard let corpus = ProjectCorpusSupport.openCorpora()
            .first(where: { $0.registration.applicationID == "xcode" })
        else {
            print("  ✗ no Xcode project is open. Open Xcode on a real Swift checkout"
                + " (this repository works) and try again.")
            exit(1)
        }
        check(true, "a project resolved off the marker climb", corpus.name)
        check(true, "the root", corpus.projectRoot.path)

        let activation = await VerifiedActivation.bringForward(
            pid: corpus.processIdentifier, requireVisibleWindow: true)
        check(activation.succeeded, "Xcode came forward",
              activation.road.map(String.init(describing:))
                  ?? activation.reason(app: corpus.registration.displayName) ?? "refused")

        heading("the real lead")
        WorkspaceFocusTracker.shared.sample()
        let signal = WorkspaceFocusTracker.shared.signal()
        let leadApplicationID = signal.lead?.application
        check(leadApplicationID == corpus.registration.applicationID,
              "the tracker's own frontmost read leads with the corpus's application",
              leadApplicationID ?? "none")

        let query = value("--query") ?? "PluginCorpusStructureSchema"
        let utterance = value("--utterance") ?? "find where the code mentions \(query)"
        let route = AmbientEngine.resolve(AmbientEngine.Inputs.live(
            utterance: utterance,
            signal: signal,
            profiles: profiles))
        AmbientContextStore.shared.noteUtterance(utterance)
        AmbientContextStore.shared.noteRoute(route)
        check(route.leadPlace?.application == corpus.registration.applicationID,
              "the route's lead place names the corpus's application",
              route.leadPlace?.token ?? "none")
        // UNLIKE SCRIVENER, this is expected to read "coding" — the corpus
        // skills' OWN Ability is still "writing", which is exactly the
        // tension this probe measures below rather than assumes away.
        print("      workspace family: \(route.leadPlace?.ability?.rawValue ?? "none")"
            + "  (Scrivener reads \"writing\" here; Xcode reads \"coding\")")

        heading("what the model would actually be offered")
        let log = AbilityExecutionLog()
        let runtime = AbilityRuntime(
            plugins: adapters, executionLog: log,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let offered = Set(runtime.schemas.map(\.name))
        var allOffered = true
        for wanted in [
            "search_corpus", "read_corpus_outline", "read_corpus_document", "corpus_progress",
        ] {
            let present = offered.contains(wanted)
            allOffered = allOffered && present
            check(present, "\(wanted) is in this turn's roster")
        }

        guard allOffered else {
            print("""

              ✗ The corpus skills did not project for this turn. This is the
                known tension recorded above: they are declared inside
                writing.mary, whose Ability-level routing policy admits a
                coding workspace only via a classified compose/revise intent
                or a live text-selection interaction — never via
                workspaceFamily=="coding" alone
                (WritingReachabilityTests.aCodingWorkspaceStillDoesNotAdmitWriting
                pins this on purpose). Try --utterance with an imperative
                phrasing, or see the probe's header for what this measures.
            """)
            AmbientContextStore.shared.noteRoute(route)
            exit(1)
        }

        heading("dispatching search_corpus for real")
        let searchOutcome = await runtime.dispatch(
            name: "search_corpus",
            argumentsJSON: #"{"query":"\#(query)"}"#)
        check(searchOutcome.ok, "search_corpus dispatched without a refusal")
        check(!searchOutcome.foundNothing, "and it found the word in a real file",
              "query \"\(query)\"")
        print("      \(searchOutcome.summary.replacingOccurrences(of: "\n", with: "\n      "))")

        heading("dispatching read_corpus_outline and read_corpus_document for real")
        let outlineOutcome = await runtime.dispatch(
            name: "read_corpus_outline", argumentsJSON: "{}")
        check(outlineOutcome.ok, "read_corpus_outline dispatched")
        print("      \(outlineOutcome.summary.prefix(400))…")
        // Outline must exclude .build / .git / DerivedData.
        for leaked in [".build/", "DerivedData/", ".git/"] {
            check(!outlineOutcome.summary.contains(leaked),
                  "the outline does not leak \(leaked)")
        }

        let firstDocument = value("--read") ?? "ProjectCorpusReader"
        let documentOutcome = await runtime.dispatch(
            name: "read_corpus_document",
            argumentsJSON: #"{"document":"\#(firstDocument)"}"#)
        check(documentOutcome.ok, "read_corpus_document dispatched", firstDocument)
        print("      \(documentOutcome.summary.prefix(200))…")
        // REAL SOURCE, not markup or a decode artefact — the reader's
        // `.plainText` branch is a raw UTF-8 read, so this should be Swift.
        check(documentOutcome.summary.contains("func ") || documentOutcome.summary.contains("struct "),
              "and it reads as real Swift, not a decode artefact")

        heading("dispatching corpus_progress for real")
        let progressOutcome = await runtime.dispatch(
            name: "corpus_progress", argumentsJSON: "{}")
        check(progressOutcome.ok, "corpus_progress dispatched")
        print("      \(progressOutcome.summary)")

        AmbientContextStore.shared.noteRoute(route)
    }

    /// Measured scrivener.mary structure schema; validated before use.
    static var scrivenerLike: PluginCorpusStructureSchema {
        .init(
            discovery: .directoryExtension,
            projectExtension: "scriv",
            openState: [.lockFile, .runningApplication],
            // MEASURED: the lock lives inside `Files/`, not at the project
            // root. A path that is merely plausible reports every project as
            // closed, and reports it silently.
            lockFilePath: "Files/user.lock",
            manifest: .init(
                kind: .xmlManifest,
                pathTemplate: "{name}.scrivx",
                rootElement: "Binder",
                itemElement: "BinderItem",
                idAttribute: "UUID",
                titleElement: "Title",
                childrenElement: "Children",
                typeAttribute: "Type",
                containerTypes: ["Folder", "DraftFolder", "ResearchFolder", "TrashFolder"],
                draftType: "DraftFolder",
                trashType: "TrashFolder"),
            parts: [
                .init(name: "text", pathTemplate: "Files/Data/{id}/content.rtf", format: .rtf),
            ],
            documentURLTemplate: "x-scrivener-item:///{project}?id={id}",
            handlePrefix: "D",
            ceremonies: [
                .init(act: .addItem, menuPath: ["Project", "New Text"]),
                .init(act: .addContainer, menuPath: ["Project", "New Folder"]),
                .init(act: .moveToContainer, menuPath: ["Documents", "Move To"],
                      completedByContainer: true),
                .init(act: .trash, menuPath: ["Documents", "Move to Trash"]),
            ])
    }

    static func run(_ arguments: [String]) async {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }

        if arguments.contains("--live") {
            await runLive()
            return
        }

        if arguments.contains("--dispatch") {
            await runDispatch(arguments)
            return
        }

        if arguments.contains("--dispatch-code") {
            await runDispatchCode(arguments)
            return
        }

        guard let raw = value("--project") else {
            print("""
            Pass --project <path to a .scriv>, --live to go through the shipped \
            packages, --dispatch to drive search_corpus through real dispatch with \
            Scrivener as the lead, or --dispatch-code to do the same with Xcode
            """)
            exit(1)
        }
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let structure = scrivenerLike

        // ADMISSION FIRST. A declaration that the package system would refuse
        // is not worth measuring — and measuring it anyway is how a probe
        // reports success for a package that can never load.
        var admissionIssues: [String] = []
        PluginValidator.validateCorpusStructure(
            structure, path: "probe.structure",
            error: { code, path, message in
                admissionIssues.append("\(code) at \(path): \(message)")
            })
        if admissionIssues.isEmpty {
            print("  admission   the declaration validates")
        } else {
            for issue in admissionIssues { print("  ✗ \(issue)") }
            exit(1)
        }

        print("▸ \(root.lastPathComponent)")

        let started = Date()
        switch ProjectCorpusReader.outline(projectRoot: root, structure: structure) {
        case .failure(let failure):
            print("  ✗ \(failure.spoken)")
            exit(1)
        case .success(let items):
            let flat = items.flatMap(\.flattened)
            print(String(
                format: "  outline     %.0f ms · %d top-level · %d total · %d containers",
                Date().timeIntervalSince(started) * 1000,
                items.count, flat.count, flat.filter(\.isContainer).count))

            for item in flat.prefix(24) {
                let indent = String(repeating: "  ", count: item.depth)
                let mark = item.isContainer ? "▸" : "·"
                print("    \(indent)\(mark) \(item.title.isEmpty ? "(untitled)" : item.title)"
                    + "  [\(item.type ?? "—")]")
            }
            if flat.count > 24 { print("    … \(flat.count - 24) more") }

            // THE ID IS THE JOIN between the outline and the text on disk. An
            // outline with empty ids parses perfectly and can read nothing.
            let missingIDs = flat.filter(\.id.isEmpty).count
            print("  ids         \(flat.count - missingIDs)/\(flat.count) present"
                + (missingIDs > 0 ? "  ⚠︎ \(missingIDs) EMPTY" : ""))

            // Trash must be absent from the outline (dropped by type).
            if let trashType = structure.manifest.trashType {
                let leaked = flat.filter { $0.type == trashType }
                print("  trash       \(leaked.isEmpty ? "excluded" : "⚠︎ \(leaked.count) LEAKED")")
            }

            let wanted = value("--read")
            let target = wanted.flatMap { name in
                flat.first { $0.title.localizedCaseInsensitiveContains(name) }
            } ?? flat.first { !$0.isContainer && !$0.id.isEmpty }

            guard let target else {
                print("  nothing readable in the outline.")
                return
            }
            print("\n▸ \(target.title)")
            let readStarted = Date()
            switch ProjectCorpusReader.text(
                itemID: target.id, projectRoot: root, structure: structure) {
            case .failure(let failure):
                print("  ✗ \(failure.spoken)")
            case .success(let text):
                print(String(
                    format: "  read        %.0f ms · %d characters",
                    Date().timeIntervalSince(readStarted) * 1000, text.count))
                let lines = text.split(separator: "\n").prefix(6)
                for line in lines { print("    \(line.prefix(90))") }
                // RTF THAT DECODED TO MARKUP is the failure that looks like
                // success: a string comes back, it is just not prose.
                if text.contains("\\rtf") || text.contains("{\\") {
                    print("  ⚠︎ THE DECODE LEAKED RTF MARKUP — this is not prose.")
                }
            }
        }
    }
}

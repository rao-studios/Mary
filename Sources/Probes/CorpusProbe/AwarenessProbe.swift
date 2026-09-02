//
//  AwarenessProbe.swift
//  CorpusProbe
//
//  WHAT: The awareness faculty against a real editor and a real project.
//  OUT:  CLI: mary-corpus-probe --awareness [--app X] [--utterance "…"]
//  PIN:  Dispatches through the REAL AbilityRuntime, so the roster gate this
//        pass deliberately outruns is exercised rather than described.
//

import ApplicationServices
import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum AwarenessProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("--awareness")
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
        let observers = MaryAdapterCatalog.observers()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: observers),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        check(load.activated, "the packages loaded", "\(load.snapshot.records.count)")
        for issue in load.issues where issue.severity == .error {
            print("      ! \(issue.code): \(issue.message)")
        }

        let awareness = MaryRuntime.awarenessRegistrations(from: load.snapshot)
        AwarenessSupport.shared.reconcile(awareness)
        CodeSurfaceSupport.shared.reconcile(
            MaryRuntime.codeSurfaceRegistrations(from: load.snapshot))
        CorpusSupport.shared.reconcile(
            MaryRuntime.corpusRegistrations(from: load.snapshot))
        let profiles = adapters.map(\.applicationProfile)
            + load.snapshot.plugins.applicationProfiles
        AmbientApplicationBridge.install(profiles: profiles)
        AmbientCapabilityBridge.install()
        check(!awareness.isEmpty, "an application asked to be followed",
              awareness.map(\.applicationID).joined(separator: ", "))
        for registration in awareness {
            print("      · \(registration.applicationID) — "
                + "corpus=\(registration.corpus?.notation ?? "none") "
                + "code=\(registration.hasCodeSurface) prose=\(registration.hasProseSurface)")
        }

        heading("settling on the work")
        // DISK MODE: `--root` traces a project with no editor open at all, so
        // the grammar, the index and the caps can be measured against a real
        // repository when Xcode is not running. The live path below is the
        // real one; this is the one a test machine can always take.
        let site: AwarenessSite
        if let root = value("--root") {
            guard let registration = awareness.first(where: {
                $0.applicationID == (value("--app") ?? "xcode")
            }) else {
                print("  ✗ no followed application named \(value("--app") ?? "xcode").")
                exit(1)
            }
            let relative = value("--file") ?? "Sources/MaryPlugin/Corpus/CorpusObserver.swift"
            let absolute = URL(fileURLWithPath: root).appendingPathComponent(relative)
            guard let text = try? String(contentsOf: absolute, encoding: .utf8) else {
                print("  ✗ can't read \(absolute.path).")
                exit(1)
            }
            let caret = value("--find").flatMap { needle in
                text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
            } ?? text.count / 2
            site = AwarenessSite(
                registration: registration, root: root,
                relativePath: relative,
                fileName: (relative as NSString).lastPathComponent,
                text: text, caret: caret, highlight: nil, isLive: false)
        } else {
            // The surface observers publish the sight awareness resolves against.
            for observer in observers { await observer.activate() }
            for observer in observers where !observer.ambientSenses.isEmpty {
                await observer.refreshAmbientContext()
            }
            guard let live = AwarenessSiteResolver.resolve(named: value("--app")) else {
                print("  ✗ nothing followed is in front. Open a source file in a "
                    + "followed editor, name one with --app <id>, or trace from "
                    + "disk with --root <path> [--file <relative>] [--find <text>].")
                exit(1)
            }
            site = live
        }
        check(true, "settled on \(site.fileName)",
              "\(site.registration.applicationID)"
                + (site.isLive ? ", live buffer" : ", from disk"))
        check(site.root != nil, "the project root resolved", site.root ?? "none")
        print("      relative: \(site.relativePath)  chars: \(site.text.count)"
            + "  caret: \(site.caret)"
            + (site.highlight.map { "  highlight: \($0.lowerBound)…\($0.upperBound)" } ?? ""))

        heading("the unit")
        let unitStart = DispatchTime.now()
        guard let unit = AwarenessAdapter.unit(at: site, symbol: value("--symbol")) else {
            print("  ✗ no declaration encloses the cursor. Put the caret inside "
                + "a function and try again.")
            exit(1)
        }
        check(true, "the unit at the cursor", "\(unit.display), lines \(unit.startLine)–\(unit.endLine)")
        print("      scope: \(unit.scope)")
        print("      body: \(unit.body.count) chars, whole=\(unit.isWhole)")
        print("      located in \(elapsed(since: unitStart))")

        heading("the bearings")
        guard let root = site.root, let corpus = site.corpus else {
            print("  ✗ no project grammar to trace through.")
            exit(1)
        }
        let indexStart = DispatchTime.now()
        let declarations = CorpusDeclarationIndexCache.shared.index(root: root, corpus: corpus)
        check(declarations.count > 0, "the declaration index built",
              "\(declarations.count) declarations in \(elapsed(since: indexStart))")

        let callerStart = DispatchTime.now()
        let callers = CorpusTracer.callers(
            of: unit.name, root: root, corpus: corpus, declarations: declarations)
        check(true, "callers", "\(callers.count) in \(elapsed(since: callerStart))")
        for hit in callers { print("      \(AwarenessBrief.line(hit))") }

        let calleeStart = DispatchTime.now()
        let callees = CorpusTracer.callees(
            in: unit.body, own: unit.name, corpus: corpus,
            declarations: declarations, in: site.relativePath)
        check(true, "callees", "\(callees.count) in \(elapsed(since: calleeStart))")
        for hit in callees { print("      \(AwarenessBrief.line(hit))") }

        let utterance = value("--utterance") ?? "what do you think about this code"
        var matches: [TraceHit] = []
        let searchStart = DispatchTime.now()
        for word in CorpusTracer.contentWords(of: utterance) where matches.isEmpty {
            matches = CorpusTracer.search(
                for: word, root: root, corpus: corpus, declarations: declarations)
        }
        check(true, "words from \"\(utterance)\"",
              "\(matches.count) in \(elapsed(since: searchStart))")
        for hit in matches { print("      \(AwarenessBrief.line(hit))") }

        heading("the standing brief")
        let brief = AwarenessBrief.standing(
            unit: unit, fileName: site.fileName, callers: callers, callees: callees)
        print(brief.split(separator: "\n").map { "      \($0)" }.joined(separator: "\n"))
        check(brief.count <= AwarenessBrief.standingBudget,
              "the standing brief fits its budget",
              "\(brief.count)/\(AwarenessBrief.standingBudget)")

        guard value("--root") == nil else {
            print("\n  (disk mode — the live dispatch section needs an editor in front)")
            return
        }

        heading("through the real runtime")
        WorkspaceFocusTracker.shared.sample()
        let signal = WorkspaceFocusTracker.shared.signal()
        let route = AmbientEngine.resolve(AmbientEngine.Inputs.live(
            utterance: utterance, signal: signal, profiles: profiles))
        AmbientContextStore.shared.noteUtterance(utterance)
        AmbientContextStore.shared.noteRoute(route)
        print("      route: intent=\(route.intent.rawValue) "
            + "lead=\(route.leadPlace?.token ?? "none") "
            + "deictic=\(route.verdicts.isDeictic)")

        let runtime = AbilityRuntime(
            plugins: adapters,
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        // THE GATE THIS PASS OUTRUNS: project the roster first, exactly as the
        // turn loop does, so a blocked dispatch would show up here.
        let offered = Set(runtime.schemas.map(\.name))
        print("      awareness in this turn's roster: "
            + "\(offered.contains("read_enclosing_unit") ? "yes" : "no — the pre-read outruns it)")")

        let dispatchStart = DispatchTime.now()
        let sight = await runtime.fetchAwareness(query: utterance)
        check(sight != nil, "the pre-lane awareness pass served",
              elapsed(since: dispatchStart))
        if let sight {
            if let unitText = sight.unit {
                print("      unit: \(unitText.count) chars")
                print(unitText.prefix(400).split(separator: "\n")
                    .map { "      | \($0)" }.joined(separator: "\n"))
            }
            if let surroundings = sight.surroundings {
                print("      surroundings: \(surroundings.count) chars")
                print(surroundings.split(separator: "\n")
                    .map { "      | \($0)" }.joined(separator: "\n"))
            }
        }
    }

    static func elapsed(since start: DispatchTime) -> String {
        let ms = (DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
        return "\(ms)ms"
    }
}

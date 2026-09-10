//
//  AnnotationProbe.swift
//  CorpusProbe — `mary-corpus-probe annotate`
//
//  WHAT: Real unit through the install's annotator → ledger `.ran`.
//  OUT:  CLI: mary-corpus-probe annotate [--engine local|hosted] [--file …]
//  PIN:  Reads the install's own config (not a hardcoded hosted path).
//

import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum AnnotationProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("annotate") || arguments.contains("--annotate")
    }

    static func run(_ arguments: [String]) async -> Int {
        var failures = 0
        func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
            print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : " — \(detail)")")
            if !passed { failures += 1 }
        }
        func value(_ argument: String) -> String? {
            arguments.firstIndex(of: argument).flatMap { index in
                index + 1 < arguments.count ? arguments[index + 1] : nil
            }
        }

        DotEnv.loadMaryEnvironment()

        // MARK: - The mode this install actually runs

        heading("the mode this install runs")

        // THE PERSISTED CHOICE, not a default. `ConfigService.Center.State()`
        // is a fresh install's answer, and the whole question here is what
        // THIS machine is set to.
        let stored = PersistedConfig.load()
        var engine = stored?.engine ?? .mistral
        let sewnEnabled = stored?.sewnEnabled ?? true
        if let override = value("--engine") {
            guard let parsed = LLMEngineChoice(rawValue: override) else {
                print("Unknown engine '\(override)' — use mistral, local, or tinker.")
                return 1
            }
            engine = parsed
            print("      (engine overridden to \(parsed.rawValue))")
        }
        check(stored != nil, "read the persisted config",
              stored == nil ? "none on disk — assuming defaults" : PersistedConfig.path)
        print("      llmEngine: \(engine.rawValue)   sewnEnabled: \(sewnEnabled)")

        let hosted = MaryRuntime.sewnCarriesTurns(engine: engine, sewnEnabled: sewnEnabled)
        print("      → annotation always rides Sewn's /v1/complete; the backend "
            + "behind it is \(engine.displayName)")

        // MARK: - The annotator

        heading("the annotator")

        var defaults = ConfigService.Center.State()
        if let stored {
            defaults.sewnPort = stored.sewnPort
            defaults.sewnEmail = stored.sewnEmail
            defaults.sewnPassword = stored.sewnPassword
        }
        let annotator: any UnitAnnotating
        if true {
            // SIGN IN FIRST. `SewnUnitAnnotator` answers nil when the session
            // is not authenticated, and a probe that skipped this would report
            // the boot race as if it were the steady state.
            if let error = await MaryRuntime.applySewnAccount(
                email: defaults.sewnEmail,
                password: defaults.sewnPassword,
                sewnPort: defaults.sewnPort) {
                check(false, "signed in to Sewn", error)
                return 1
            }
            let owner = await MaryRuntime.sewnSession.userID ?? "?"
            check(true, "signed in to Sewn", owner)
            await MaryRuntime.setAnnotationProvider(engine)
            annotator = MaryRuntime.makeSewnUnitAnnotator()
        }
        let refuses = annotator.refusesToAnnotate
        print("      refusesToAnnotate: \(refuses)")

        // MARK: - A real unit

        heading("a real unit")

        let adapters = MaryAdapterCatalog.adapters()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: MaryAdapterCatalog.observers()),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])
        let registrations = MaryRuntime.corpusRegistrations(from: load.snapshot)
        CorpusSupport.shared.reconcile(registrations)
        guard let registration = registrations.first(where: { !$0.schema.include.isEmpty })
        else {
            check(false, "a package declares a crawlable corpus")
            return 1
        }

        // THIS CHECKOUT is the project, so the probe needs no editor open: the
        // question here is the annotation round, not the AX read that the
        // crawl lane already covers.
        let root = FileManager.default.currentDirectoryPath
        let relativePath = value("--file")
            ?? "Sources/MaryAmbient/Ambient/Indexing/UnitIndex.swift"
        let absolute = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(relativePath).path
        check(FileManager.default.fileExists(atPath: absolute),
              "the unit exists on disk", relativePath)

        let corpus = registration.schema
        let paths = CorpusCrawl.projectFiles(root: root, corpus: corpus)
        let index = CorpusTypeIndex(
            root: root,
            files: paths.map { path in
                (relativePath: path,
                 declaredNames: CorpusCrawl.read(
                    relativePath: path, root: root, corpus: corpus)?.declaredNames ?? [])
            })
        let units = CorpusCrawl.crawl(
            focusedPath: absolute, root: root, projectName: (root as NSString).lastPathComponent,
            corpus: corpus, index: index, applicationID: registration.applicationID)
        guard let unit = units.first else {
            check(false, "the crawl produced a unit to annotate")
            return 1
        }
        check(true, "crawled", "\(unit.relativePath), \(unit.declaredTypes.count) declared types, "
            + "\(unit.apiHeaders.count) headers")

        // MARK: - Through the real coordinator

        heading("through the real coordinator, into the real ledger")

        // A LEDGER OF ITS OWN, never `.shared`: the pane's inventory is not
        // this probe's to overwrite.
        let ledger = UnitIndexLedger()
        let indexer = AmbientUnitIndexingCoordinator(
            idleFor: 0.1, annotator: annotator, ledger: ledger) { _, _ in }
        let started = Date()
        await indexer.ingest(unit)
        await indexer.flush()
        let elapsed = Date().timeIntervalSince(started)

        guard let record = ledger.allUnits().first(where: {
            $0.relativePath == unit.relativePath
        }) else {
            check(false, "the ledger holds a record for it")
            return 1
        }
        print(String(format: "      round took %.1fs", elapsed))
        print("      outcome: .\(record.annotation.rawValue)")
        print("      the pane will read: \"\(statusLine(for: record.annotation))\"")
        if let precis = record.precis {
            print("      précis: \(precis)")
        }
        if !record.labels.isEmpty {
            print("      labels: \(record.labels.joined(separator: ", "))")
        }

        // On-device decline is the correct outcome; do not assert `.ran`.
        if refuses {
            check(record.annotation == .refusedExclusiveEngine,
                  "declined by policy, as the on-device lane is meant to",
                  record.annotation.rawValue)
        } else {
            check(record.annotation == .ran,
                  "the unit is SUMMARISED", record.annotation.rawValue)
            check(record.precis?.isEmpty == false, "it carries a précis")
            check(!record.labels.isEmpty, "and conceptual labels",
                  "\(record.labels.count)")
        }

        heading("── THE VERDICT ──")
        if failures == 0 {
            print("""
              A real unit, through the annotator this install actually wires,
              reached the ledger with the outcome the Corpus pane renders.
            """)
        } else {
            print("  \(failures) check(s) failed.")
        }
        return failures == 0 ? 0 : 1
    }

    /// Mirror of CorpusViewModel.statusLine (app target; keep wording in sync).
    static func statusLine(for outcome: UnitAnnotationOutcome) -> String {
        switch outcome {
        case .pending: return "waiting to be summarised"
        case .ran: return "summarised"
        case .pinned: return "labels pinned by you"
        case .noAnnotator: return "structure only — no summariser installed"
        case .refusedExclusiveEngine:
            return "structure only — the on-device engine is reserved for your turns"
        case .failed: return "structure only — the summariser returned nothing"
        case .sewnUnavailable: return "structure only — Sewn is not signed in"
        case .empty: return "structure only — the summariser returned an empty reply"
        case .unparsable: return "structure only — the summariser did not return a précis"
        case .unknown: return "in a state this version doesn't recognise"
        }
    }
}

// MARK: - The persisted config

/// Brain card on disk (`mary.persistence.config.0001`), without booting Granite.
enum PersistedConfig {

    struct Values {
        var engine: LLMEngineChoice
        var sewnEnabled: Bool
        var sewnPort: Int
        var sewnEmail: String
        var sewnPassword: String
    }

    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Application Support/nyc.rao.mary/granite-db/mary.persistence.config.0001")
    }

    static func load() -> Values? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              let state = root["state"] as? [String: Any]
        else { return nil }
        let defaults = ConfigService.Center.State()
        return Values(
            engine: (state["llmEngine"] as? String).flatMap(LLMEngineChoice.init(rawValue:))
                ?? defaults.llmEngine,
            sewnEnabled: state["sewnEnabled"] as? Bool ?? defaults.sewnEnabled,
            sewnPort: state["sewnPort"] as? Int ?? defaults.sewnPort,
            sewnEmail: state["sewnEmail"] as? String ?? defaults.sewnEmail,
            sewnPassword: state["sewnPassword"] as? String ?? defaults.sewnPassword)
    }
}

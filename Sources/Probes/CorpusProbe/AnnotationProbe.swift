//
//  AnnotationProbe.swift
//  CorpusProbe — `mary-corpus-probe annotate`
//
//  THE JOIN NOTHING ELSE MAKES: does a REAL unit, through the REAL annotator
//  the app wires in this install's engine mode, reach the ledger as
//  `.ran` — the outcome the Corpus pane renders as "summarised"?
//
//  Every other lane of this probe stops short of annotation on purpose: the
//  crawl half builds its coordinators with `ledger: nil` and no annotator at
//  all, because what it is asking about is the crawl. So the one step that
//  costs a model round — and the only step that can fail against a live
//  server — had no live coverage anywhere, and a defect in it was invisible
//  outside the Corpus pane's own status line.
//
//  It found one. `SeerUnitAnnotator` sent `instructions: nil`, dropping the
//  JSON contract `InferenceUnitAnnotator.parse` enforces, and Seer's chat —
//  a persona lane with retrieval, not a completion endpoint — answered in
//  prose. Every unit in hosted mode came back `.failed`.
//
//  IT READS THE INSTALL'S OWN CONFIG rather than assuming a mode. Which
//  annotator can answer depends on the Brain card's choice and on
//  `seerEnabled`, and a probe that hardcoded hosted would prove nothing about
//  the machine it ran on. `--engine local|hosted` overrides for the other
//  half of the truth table.
//
//    mary-corpus-probe annotate
//    mary-corpus-probe annotate --engine local
//    mary-corpus-probe annotate --file Sources/MaryAmbient/.../UnitIndex.swift
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
        var engine = stored?.engine ?? .hosted
        let seerEnabled = stored?.seerEnabled ?? true
        if let override = value("--engine") {
            guard let parsed = LLMEngineChoice(rawValue: override) else {
                print("Unknown engine '\(override)' — use local or hosted.")
                return 1
            }
            engine = parsed
            print("      (engine overridden to \(parsed.rawValue))")
        }
        check(stored != nil, "read the persisted config",
              stored == nil ? "none on disk — assuming defaults" : PersistedConfig.path)
        print("      llmEngine: \(engine.rawValue)   seerEnabled: \(seerEnabled)")

        let hosted = MaryRuntime.seerCarriesTurns(engine: engine, seerEnabled: seerEnabled)
        print("      → the annotator the app wires here: "
            + (hosted ? "SeerUnitAnnotator" : "InferenceUnitAnnotator"))

        // MARK: - The annotator

        heading("the annotator")

        var defaults = ConfigService.Center.State()
        if let stored {
            defaults.seerPort = stored.seerPort
            defaults.seerEmail = stored.seerEmail
            defaults.seerPassword = stored.seerPassword
        }
        let annotator: any UnitAnnotating
        if hosted {
            // SIGN IN FIRST. `SeerUnitAnnotator` answers nil when the session
            // is not authenticated, and a probe that skipped this would report
            // the boot race as if it were the steady state.
            if let error = await MaryRuntime.applySeerAccount(
                email: defaults.seerEmail,
                password: defaults.seerPassword,
                seerPort: defaults.seerPort) {
                check(false, "signed in to Seer", error)
                return 1
            }
            let owner = await MaryRuntime.seerSession.userID ?? "?"
            check(true, "signed in to Seer", owner)
            annotator = MaryRuntime.makeSeerUnitAnnotator()
        } else {
            annotator = InferenceUnitAnnotator(engine: MaryLocalEngine(
                modelID: stored?.localModelID ?? MaryLocalEngine.defaultModelID))
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

        // THE ASSERTION, AND IT DIFFERS BY MODE ON PURPOSE. On device,
        // declining IS the correct outcome and the pane says so; asserting
        // `.ran` there would be asserting a product decision this probe does
        // not get to make.
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

    /// `CorpusViewModel.statusLine` lives in the app target, which neither a
    /// probe nor a test target can import — MaryApp has no test target at all.
    /// Mirrored here so the probe prints the sentence the user will actually
    /// see, and kept honest by hand: if a branch there changes wording, change
    /// it here. The mirror is worth the duplication because the outcome enum
    /// alone (`.failed`) does not tell you what the user is looking at, and
    /// what the user is looking at is the entire report.
    static func statusLine(for outcome: UnitAnnotationOutcome) -> String {
        switch outcome {
        case .pending: return "waiting to be summarised"
        case .ran: return "summarised"
        case .pinned: return "labels pinned by you"
        case .noAnnotator: return "structure only — no summariser installed"
        case .refusedExclusiveEngine:
            return "structure only — the on-device engine is reserved for your turns"
        case .failed: return "structure only — the summariser returned nothing"
        case .seerUnavailable: return "structure only — Seer is not signed in"
        case .empty: return "structure only — the summariser returned an empty reply"
        case .unparsable: return "structure only — the summariser did not return a précis"
        case .unknown: return "in a state this version doesn't recognise"
        }
    }
}

// MARK: - The persisted config

/// The Brain card's choice as it sits on disk, read WITHOUT booting Granite.
///
/// The store is a binary plist under the app's own support directory, written
/// by `@Store(persist: "mary.persistence.config.0001")`. A probe that spun up
/// the real service to read three fields would also adopt its autosave, and
/// the point here is to observe the install, not to write to it.
enum PersistedConfig {

    struct Values {
        var engine: LLMEngineChoice
        var seerEnabled: Bool
        var localModelID: String
        var seerPort: Int
        var seerEmail: String
        var seerPassword: String
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
            seerEnabled: state["seerEnabled"] as? Bool ?? defaults.seerEnabled,
            localModelID: state["localModelID"] as? String ?? defaults.localModelID,
            seerPort: state["seerPort"] as? Int ?? defaults.seerPort,
            seerEmail: state["seerEmail"] as? String ?? defaults.seerEmail,
            seerPassword: state["seerPassword"] as? String ?? defaults.seerPassword)
    }
}

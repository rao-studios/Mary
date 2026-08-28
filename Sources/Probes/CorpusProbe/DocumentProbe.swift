//
//  DocumentProbe.swift
//  CorpusProbe
//
//  READING A REAL MANUSCRIPT — the document-corpus lane against a project
//  nobody wrote for it.
//
//  The reader's rules are testable against a synthetic manifest, and a
//  synthetic manifest is written by the person who wrote the reader. What it
//  cannot tell you is whether a real `.scrivx` uses the element names you
//  assumed, whether an item's id is an attribute or a child, whether the
//  trash is a type or a location, or whether RTF written by a real editor
//  decodes to prose. Those are facts about a file format, and only a real
//  file has them.
//
//    mary-corpus-probe document --project ~/path/to/thing.scriv
//    mary-corpus-probe document --project … --read "Prologue"
//

import Foundation
import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum DocumentProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("document")
    }

    /// The declaration `scrivener.mary` will carry, written from the measured
    /// project rather than from the predecessor's file — same values, but
    /// checked here first.
    static var scrivenerLike: PluginCorpusStructureSchema {
        .init(
            discovery: .directoryExtension,
            projectExtension: "scriv",
            openState: [.lockFile, .runningApplication],
            lockFilePath: "user.lock",
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

        if arguments.contains("--lane") {
            await lane()
            return
        }
        guard let raw = value("--project") else {
            print("Pass --project <path to a .scriv>")
            exit(1)
        }
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let structure = scrivenerLike

        print("▸ \(root.lastPathComponent)")

        let started = Date()
        switch DocumentCorpusReader.outline(projectRoot: root, structure: structure) {
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
            switch DocumentCorpusReader.text(
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

// MARK: - The lane, through the shipped configuration

extension DocumentProbe {

    /// THE JOIN NO FIXTURE CAN MAKE: do the shipped PACKAGES declare this
    /// project correctly, and do the Skills reach the roster unblocked?
    ///
    /// `document` above proves the reader works against a real manuscript
    /// using a declaration written here. This proves `scrivener.mary` says
    /// the same thing — which is the only question a live parity pass is for,
    /// and the one a hand-built structure cannot answer.
    static func lane() async {
        var failures = 0
        func check(_ passed: Bool, _ claim: String, _ detail: String = "") {
            print("  \(passed ? "✓" : "✗")  \(claim)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !passed { failures += 1 }
        }

        ProseSurfaceSupport.shared.installBackingResolver()
        AmbientCapabilityBridge.install()
        let adapters = MaryAdapterCatalog.adapters()
        let observers = MaryAdapterCatalog.observers()
        let load = AbilityLibrary.shared.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters, observers: observers),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            primitiveBindings: [])

        print("▸ the shipped configuration")
        check(load.activated, "the package graph activated",
              load.snapshot.records.map(\.package.ability.id.rawValue).sorted()
                .joined(separator: ", "))
        for issue in load.issues where issue.severity == .error {
            print("      ! \(issue.code): \(issue.message)")
        }

        let registrations = MaryRuntime.documentCorpusRegistrations(from: load.snapshot)
        DocumentCorpusSupport.shared.reconcile(registrations)
        AmbientApplicationBridge.install(
            profiles: adapters.map(\.applicationProfile)
                + load.snapshot.plugins.applicationProfiles)
        check(!registrations.isEmpty, "a writing project is declared",
              registrations.map(\.applicationID).sorted().joined(separator: ", "))

        // ⚠️ A NOTATION-ONLY CORPUS MUST NOT REGISTER HERE. xcode.mary
        // declares a corpus with no `structure` — files to learn style from,
        // not a project with an outline — and registering it would offer an
        // outline read against something that has none.
        check(!registrations.contains { $0.applicationID == "xcode" },
              "a notation-only corpus stays out of this lane")

        let corpora = DocumentCorpusSupport.shared.openCorpora()
        check(!corpora.isEmpty, "a project is open right now",
              corpora.map(\.name).joined(separator: ", "))

        for corpus in corpora {
            check(DocumentCorpusSupport.isOpenForEditing(corpus),
                  "\(corpus.name) is open for editing")
            let place = AmbientPlace.application(corpus.registration.applicationID)
            check(place.hasEyes, "\(corpus.registration.applicationID)'s place has eyes")
        }

        let skills = load.snapshot.skills.filter {
            $0.id.rawValue.hasPrefix("writing.")
        }
        let blocked = skills.filter { $0.availability.readiness == .blocked }
        check(blocked.isEmpty && !skills.isEmpty, "no writing skill is blocked",
              blocked.isEmpty
                ? "\(skills.count) offered"
                : blocked.map { "\($0.id.rawValue): "
                    + ($0.availability.reasons.first ?? "?") }
                    .sorted().joined(separator: "; "))

        // AND THE READ ITSELF, through the shipped adapter rather than a
        // hand-built structure — the whole point of this pass.
        guard let adapter = adapters.first(where: { $0.name == "document-corpus" }),
              let binding = adapter.skillBindings.first(
                where: { $0.name == "read_corpus_outline" }),
              case .native(let run) = binding.backing
        else {
            check(false, "read_corpus_outline is published")
            return
        }
        do {
            let outcome = try await run([:], AbilityExecutionContext(projects: [:]))
            check(outcome.ok, "read_corpus_outline answered")
            print("\n" + outcome.summary.split(separator: "\n").prefix(10)
                .joined(separator: "\n"))
        } catch {
            check(false, "read_corpus_outline threw", error.localizedDescription)
        }

        // THE OTHER READS, through the same shipped path. Each answers a
        // different question of the manuscript, and each is a different way
        // for a declaration to be subtly wrong.
        for (skill, arguments) in [
            ("corpus_progress", [:]),
            ("search_corpus", ["query": "comet"]),
            ("read_corpus_document", ["document": "Section 1.1"]),
        ] as [(String, [String: String])] {
            guard let binding = adapter.skillBindings.first(where: { $0.name == skill }),
                  case .native(let call) = binding.backing else { continue }
            print("\n▸ \(skill)")
            do {
                let outcome = try await call(arguments, AbilityExecutionContext(projects: [:]))
                print("  \(outcome.ok ? "ok" : "REFUSED")"
                    + (outcome.foundNothing ? "  (found nothing)" : ""))
                for line in outcome.summary.split(separator: "\n").prefix(5) {
                    print("    \(line.prefix(100))")
                }
            } catch {
                print("  THREW  \(error.localizedDescription)")
            }
        }

        print(failures == 0
            ? "\n  The document-corpus lane is loaded and reading."
            : "\n  \(failures) check(s) failed.")
    }
}

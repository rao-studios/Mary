//
//  ProjectProbe.swift
//  CorpusProbe
//
//  READING A REAL MANUSCRIPT — the project-corpus lane against a project
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
//    mary-corpus-probe project --project ~/path/to/thing.scriv
//    mary-corpus-probe project --project … --read "Prologue"
//    mary-corpus-probe project --live      ← through the shipped packages
//

import ApplicationServices
import Foundation
import MaryBrain
import MaryFoundation
import MaryPlugin
import MaryRuntime

enum ProjectProbe {

    static func shouldRun(_ arguments: [String]) -> Bool {
        arguments.contains("project")
    }

    /// THE WHOLE CHAIN, not the reader alone: the shipped packages, the
    /// corpus roster they produce, and the project a running application
    /// actually has open — found through its own `AXDocument` rather than
    /// through a path anybody typed.
    ///
    /// This is the half `--project <path>` cannot answer. Handing the reader a
    /// path proves the reader; it says nothing about whether `scrivener.mary`
    /// declares the right extension, whether the roster reaches the lane, or
    /// whether the application publishes the project root at all.
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

        // THE SKILLS THE MODEL WOULD SEE. A lane whose Skills install blocked
        // is a lane that does not exist as far as the model is concerned,
        // which is exactly the failure `DerivedPerceptions` was about.
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

    /// The declaration `scrivener.mary` will carry, written from the measured
    /// project rather than assumed — checked here first, because a package
    /// declaring it is a claim about somebody else's file format.
    ///
    /// IT IS RUN THROUGH THE VALIDATOR BELOW BEFORE IT IS USED, so this probe
    /// cannot measure a declaration the package system would refuse.
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

        guard let raw = value("--project") else {
            print("Pass --project <path to a .scriv>, or --live to go through the shipped packages")
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

            // THE TRASH MUST NOT BE IN THE OUTLINE AT ALL. The reader drops it
            // by type, and a real project is the only place that spelling gets
            // checked — a trashType that does not match Scrivener's would
            // exclude nothing and look exactly like a project with no trash.
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

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
import MaryFoundation
import MaryPlugin

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

//
//  ProjectCorpusAdapter+Index.swift
//  MaryPlugin
//
//  WHAT: Locate, references, open, vocabulary — shared project-lane ops.
//  IN:   ProjectCorpusAdapter / ProjectCorpusReader / ProjectCorpusSupport
//  OUT:  SkillOutcome
//  PIN:  Sibling of ProjectCorpusAdapter.swift. Nothing names an app.
//        A bundle project (`.scriv`) is never written on disk.
//

import AppKit
import Foundation
import MaryFoundation

extension ProjectCorpusAdapter {

    var locateDeclaration: SkillBinding {
        SkillBinding(
            name: "locate_declaration",
            description: "Find which file in the live project declares a named type or function.",
            parameters: [
                .init(name: "symbol", type: "string",
                      description: "The name to locate.", required: true),
                Self.projectParameter,
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let wanted = arguments["symbol"], !wanted.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which name?")
                }
                switch index(named: arguments["project"]) {
                case .refused(let outcome): return outcome
                case .ready(let corpus, let index):
                    guard let relative = index.file(declaring: wanted) else {
                        return SkillOutcome(
                            ok: true,
                            summary: "Nothing in \(corpus.name) declares \(wanted).",
                            foundNothing: true)
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: "\(wanted) is declared in \(relative).",
                        archivePolicy: .stateSnapshot,
                        adapterTrail: [AdapterID.normalized(name)])
                }
            })
    }

    var findReferences: SkillBinding {
        SkillBinding(
            name: "find_references",
            description: "Find files in the live project that refer to a named type or function.",
            parameters: [
                .init(name: "symbol", type: "string",
                      description: "The name to search for.", required: true),
                Self.projectParameter,
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let wanted = arguments["symbol"], !wanted.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which name?")
                }
                switch project(arguments["project"]) {
                case .refused(let outcome): return outcome
                case .corpus(let corpus):
                    let patterns = corpus.registration.schema.relations.references
                    let files = CorpusCrawl.projectFiles(
                        root: corpus.projectRoot.path,
                        corpus: corpus.registration.schema)
                    var hits: [String] = []
                    for relative in files {
                        let url = corpus.projectRoot.appendingPathComponent(relative)
                        guard let text = try? String(contentsOf: url, encoding: .utf8)
                        else { continue }
                        let mentioned = patterns.contains {
                            CorpusPatterns.captures($0, in: text).contains(wanted)
                        } || text.range(of: wanted) != nil
                        if mentioned { hits.append(relative) }
                        if hits.count >= 20 { break }
                    }
                    guard !hits.isEmpty else {
                        return SkillOutcome(
                            ok: true,
                            summary: "Nothing in \(corpus.name) refers to \(wanted).",
                            foundNothing: true)
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: "\(wanted) in \(corpus.name):\n"
                            + hits.joined(separator: "\n"),
                        archivePolicy: .stateSnapshot,
                        adapterTrail: [AdapterID.normalized(name)])
                }
            })
    }

    var openCorpusDocument: SkillBinding {
        SkillBinding(
            name: "open_corpus_document",
            description: "Open a document from the live project in its application. Never edits a bundle project on disk.",
            parameters: [
                .init(name: "document", type: "string",
                      description: "The document's title or path.", required: true),
                Self.projectParameter,
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let wanted = arguments["document"], !wanted.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which document?")
                }
                switch project(arguments["project"]) {
                case .refused(let outcome): return outcome
                case .corpus(let corpus):
                    if let template = corpus.structure.documentURLTemplate,
                       !template.isEmpty {
                        let filled = template
                            .replacingOccurrences(of: "{project}", with: corpus.projectRoot.path)
                            .replacingOccurrences(of: "{id}", with: wanted)
                        if let url = URL(string: filled) ?? URL(string: "file://\(filled)") {
                            _ = NSWorkspace.shared.open(url)
                            return SkillOutcome(
                                ok: true,
                                summary: "Opened \(wanted) in \(corpus.registration.displayName).")
                        }
                    }
                    if corpus.registration.structure != nil,
                       corpus.structure.projectExtension != nil {
                        return SkillOutcome(
                            ok: false,
                            summary: "I won't write into \(corpus.name) to open a document — use the application's own binder.")
                    }
                    let url = corpus.projectRoot.appendingPathComponent(wanted)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return SkillOutcome(
                            ok: true, summary: "There's no \(wanted) in \(corpus.name).",
                            foundNothing: true)
                    }
                    NSWorkspace.shared.open(url)
                    return SkillOutcome(ok: true, summary: "Opened \(wanted).")
                }
            })
    }

    var setDocumentInfo: SkillBinding {
        SkillBinding(
            name: "set_document_info",
            description: "Record a label or note about a document in the live project. Refuses to write inside a bundle project.",
            parameters: [
                .init(name: "document", type: "string",
                      description: "The document's title or path.", required: true),
                .init(name: "info", type: "string",
                      description: "The note or vocabulary value to remember.", required: true),
                Self.projectParameter,
            ],
            access: .write,
            backing: .native { arguments, _ in
                guard let document = arguments["document"], !document.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which document?")
                }
                guard let info = arguments["info"], !info.isEmpty else {
                    return SkillOutcome(ok: false, summary: "What should I remember about it?")
                }
                switch project(arguments["project"]) {
                case .refused(let outcome): return outcome
                case .corpus(let corpus):
                    if corpus.registration.structure != nil,
                       let ext = corpus.structure.projectExtension, !ext.isEmpty {
                        return SkillOutcome(
                            ok: false,
                            summary: "I won't write into a \(ext) project to set document info.")
                    }
                    let dir = corpus.projectRoot.appendingPathComponent(".mary", isDirectory: true)
                    let file = dir.appendingPathComponent("document-info.json")
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        var map: [String: String] = [:]
                        if let data = try? Data(contentsOf: file),
                           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                            map = decoded
                        }
                        map[document] = info
                        let data = try JSONEncoder().encode(map)
                        try data.write(to: file, options: .atomic)
                    } catch {
                        return SkillOutcome(
                            ok: false,
                            summary: "I couldn't save that note: \(error.localizedDescription)")
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: "Noted \(document) in \(corpus.name).")
                }
            })
    }

    enum Indexed {
        case ready(OpenCorpus, CorpusTypeIndex)
        case refused(SkillOutcome)
    }

    func index(named project: String?) -> Indexed {
        switch self.project(project) {
        case .refused(let outcome): return .refused(outcome)
        case .corpus(let corpus):
            let files = CorpusCrawl.projectFiles(
                root: corpus.projectRoot.path,
                corpus: corpus.registration.schema)
            let patterns = corpus.registration.schema.relations.declarations
            var entries: [(relativePath: String, declaredNames: [String])] = []
            for relative in files {
                let url = corpus.projectRoot.appendingPathComponent(relative)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let names = patterns.flatMap { CorpusPatterns.captures($0, in: text) }
                entries.append((relative, names))
            }
            return .ready(
                corpus,
                CorpusTypeIndex(root: corpus.projectRoot.path, files: entries))
        }
    }
}

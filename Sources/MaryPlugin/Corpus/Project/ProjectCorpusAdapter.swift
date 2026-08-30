//
//  ProjectCorpusAdapter.swift
//  MaryPlugin
//
//  WHAT: Read a writing project; change its shape through its own menus.
//  IN:   PluginCorpusStructureSchema / CorpusSupport / ProjectCorpusReader
//  OUT:  SkillOutcome / ProjectCorpusAdapter+Ceremonies / +Index
//  PIN:  Reads from disk; changes via menus (autosave would clobber a disk write).
//        Serves only corpora with `structure`. Nothing names an application.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

public struct ProjectCorpusAdapter: MaryAdapter {

    public let name = "project-corpus"
    public let summary =
        "reads a writing project's outline and text, and changes its shape through its own menus"

    /// Empty set on purpose — claiming an app would collide with the package that owns it.
    public let applicationIdentifiers: Set<String> = []
    public let abilities: Set<AbilityID> = [.writing, .coding]

    public init() {}

    public var skillBindings: [SkillBinding] {
        [readOutline, readDocument, searchCorpus, corpusProgress,
         locateDeclaration, findReferences, openCorpusDocument, setDocumentInfo]
            + ceremonyBindings
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String, capability: CapabilityID,
            input: ValueTypeID, output: ValueTypeID
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID, operation: name,
                capabilities: capability == "corpus.read"
                    ? [capability, "code.corpus.read"]
                    : [capability],
                inputTypes: [input], outputTypes: [output],
                observesPerceptions: ["perception.project-corpus"],
                targetClasses: ["writing-project", "code-workspace"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            // Spoken title — an unavailable adapter reports as "The \(title) adapter is unavailable".
            title: "Project Corpus",
            transport: .accessibility,
            operations: [
                operation(
                    "read_corpus_outline", capability: "corpus.read",
                    input: "writing.corpus-query", output: "writing.corpus-outline"),
                operation(
                    "read_corpus_document", capability: "corpus.read",
                    input: "writing.corpus-query", output: "writing.corpus-text"),
                operation(
                    "search_corpus", capability: "corpus.read",
                    input: "writing.corpus-query", output: "writing.corpus-outline"),
                operation(
                    "corpus_progress", capability: "corpus.read",
                    input: "writing.corpus-query", output: "writing.corpus-progress"),
                operation(
                    "add_corpus_item", capability: "corpus.restructure",
                    input: "writing.corpus-query", output: "writing.corpus-progress"),
                operation(
                    "add_corpus_container", capability: "corpus.restructure",
                    input: "writing.corpus-query", output: "writing.corpus-progress"),
                operation(
                    "move_corpus_item", capability: "corpus.restructure",
                    input: "writing.corpus-query", output: "writing.corpus-progress"),
                operation(
                    "trash_corpus_item", capability: "corpus.restructure",
                    input: "writing.corpus-query", output: "writing.corpus-progress"),
                operation(
                    "locate_declaration", capability: "corpus.read",
                    input: "writing.corpus-query", output: "writing.corpus-outline"),
                operation(
                    "find_references", capability: "corpus.read",
                    input: "writing.corpus-query", output: "writing.corpus-outline"),
                operation(
                    "open_corpus_document", capability: "corpus.read",
                    input: "writing.corpus-query", output: "writing.corpus-progress"),
                operation(
                    "set_document_info", capability: "corpus.restructure",
                    input: "writing.corpus-query", output: "writing.corpus-progress"),
            ],
            providesPerceptions: ["perception.project-corpus"],
            supportedValueTypes: [
                "writing.corpus-query",
                "writing.corpus-outline",
                "writing.corpus-text",
                "writing.corpus-progress",
            ],
            grantedPermissions: [.accessibility])
    }

    // MARK: - Resolving

    enum Resolved {
        case corpus(OpenCorpus)
        case refused(SkillOutcome)
    }

    func project(_ named: String?) -> Resolved {
        switch ProjectCorpusSupport.resolve(named) {
        case .success(let corpus): return .corpus(corpus)
        case .failure(let refusal):
            return .refused(SkillOutcome(ok: false, summary: refusal.spoken))
        }
    }

    /// Same two-case shape as `Resolved`. Failure is a spoken sentence, not an error.
    enum Outlined {
        case items([ProjectCorpusReader.Item])
        case refused(SkillOutcome)
    }

    func outline(_ corpus: OpenCorpus) -> Outlined {
        switch ProjectCorpusReader.outline(
            projectRoot: corpus.projectRoot, structure: corpus.structure,
            // Same exclude/include as CorpusCrawl.projectFiles — no manifest
            // bounds a `.fileSystemTree` checkout.
            excludeNames: corpus.registration.schema.exclude,
            includeExtensions: corpus.registration.schema.include) {
        case .success(let items): return .items(items)
        case .failure(let failure):
            return .refused(SkillOutcome(ok: false, summary: failure.spoken))
        }
    }

    static let projectParameter = ModelSkillSchema.Parameter(
        name: "project", type: "string",
        description: """
        Which project. ALWAYS pass this when the user names a project, or \
        when more than one might be open — omit only when there is clearly \
        just one.
        """,
        required: false)

    // MARK: - Reading

    private var readOutline: SkillBinding {
        SkillBinding(
            name: "read_corpus_outline",
            description: """
            List a writing project's or code repository's folders and \
            documents, in order — the manuscript's outline, or a repo's file \
            tree. Call this before guessing at how a project is laid out.
            """,
            parameters: [
                .init(
                    name: "under", type: "string",
                    description: "Only the part under this folder. Omit for the whole project.",
                    required: false),
                Self.projectParameter,
            ],
            access: .read,
            backing: .native { arguments, _ in
                let corpus: OpenCorpus
                switch project(arguments["project"]) {
                case .corpus(let found): corpus = found
                case .refused(let outcome): return outcome
                }
                let items: [ProjectCorpusReader.Item]
                switch outline(corpus) {
                case .items(let found): items = found
                case .refused(let outcome): return outcome
                }

                var shown = items
                if let under = arguments["under"], !under.isEmpty {
                    guard let branch = items.flatMap(\.flattened).first(where: {
                        $0.title.localizedCaseInsensitiveContains(under)
                    }) else {
                        return SkillOutcome(
                            ok: true,
                            summary: "There's no \(under) in \(corpus.name).",
                            foundNothing: true)
                    }
                    shown = [branch]
                }

                let flat = shown.flatMap(\.flattened)
                let lines = flat.prefix(Self.spokenLimit).map { item -> String in
                    String(repeating: "  ", count: item.depth)
                        + (item.isContainer ? "▸ " : "· ")
                        + (item.title.isEmpty ? "(untitled)" : item.title)
                }
                let more = flat.count > Self.spokenLimit
                    ? "\n… and \(flat.count - Self.spokenLimit) more."
                    : ""
                return SkillOutcome(
                    ok: true,
                    summary: "\(corpus.name):\n" + lines.joined(separator: "\n") + more,
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    private var readDocument: SkillBinding {
        SkillBinding(
            name: "read_corpus_document",
            description: """
            Read one document's or source file's full text out of a writing \
            project or code repository, by its title or filename. Prefer \
            this over describing content you have not actually read this turn.
            """,
            parameters: [
                .init(
                    name: "document", type: "string",
                    description: "The document's title, as the outline shows it.",
                    required: true),
                Self.projectParameter,
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let wanted = arguments["document"], !wanted.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which document?")
                }
                let corpus: OpenCorpus
                switch project(arguments["project"]) {
                case .corpus(let found): corpus = found
                case .refused(let outcome): return outcome
                }
                let items: [ProjectCorpusReader.Item]
                switch outline(corpus) {
                case .items(let found): items = found
                case .refused(let outcome): return outcome
                }

                switch Self.locate(wanted, in: items.flatMap(\.flattened)) {
                case .none:
                    return SkillOutcome(
                        ok: true,
                        summary: "There's nothing called \(wanted) in \(corpus.name).",
                        foundNothing: true)
                case .many(let rivals):
                    // Manuscripts repeat titles. Name the rivals; do not pick one.
                    return SkillOutcome(
                        ok: false,
                        summary: "\(corpus.name) has \(rivals.count) documents called "
                            + "\(wanted). Say which folder it's in.")
                case .one(let item):
                    switch ProjectCorpusReader.text(
                        itemID: item.id, projectRoot: corpus.projectRoot,
                        structure: corpus.structure) {
                    case .failure(let failure):
                        return SkillOutcome(
                            ok: true, summary: failure.spoken, foundNothing: true)
                    case .success(let text):
                        return SkillOutcome(
                            ok: true,
                            summary: "\(item.title):\n" + TextBudget.truncate(text, limit: 12000),
                            archivePolicy: .stateSnapshot,
                            adapterTrail: [AdapterID.normalized(name)])
                    }
                }
            })
    }

    private var searchCorpus: SkillBinding {
        SkillBinding(
            name: "search_corpus",
            description: """
            Search every file in a writing project or code repository for a \
            word or phrase, and return the real matching text. Any "where \
            do I mention X", "where do I handle X", or "find the place that \
            does Y" goes here — call this before falling back to a generic \
            answer about content you have not actually read this turn.
            """,
            parameters: [
                .init(
                    name: "query", type: "string",
                    description: "The word or phrase to look for.", required: true),
                Self.projectParameter,
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let query = arguments["query"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty
                else { return SkillOutcome(ok: false, summary: "What should I look for?") }

                let corpus: OpenCorpus
                switch project(arguments["project"]) {
                case .corpus(let found): corpus = found
                case .refused(let outcome): return outcome
                }
                let items: [ProjectCorpusReader.Item]
                switch outline(corpus) {
                case .items(let found): items = found
                case .refused(let outcome): return outcome
                }

                // Walk and scan, not an index — always current; no foreign format.
                var hits: [(title: String, snippet: String)] = []
                for item in items.flatMap(\.flattened) where !item.isContainer {
                    guard hits.count < Self.searchLimit else { break }
                    guard case .success(let text) = ProjectCorpusReader.text(
                        itemID: item.id, projectRoot: corpus.projectRoot,
                        structure: corpus.structure) else { continue }
                    guard let range = text.range(
                        of: query, options: [.caseInsensitive, .diacriticInsensitive])
                    else { continue }
                    hits.append((item.title, Self.snippet(text, around: range)))
                }

                guard !hits.isEmpty else {
                    return SkillOutcome(
                        ok: true,
                        summary: "Nothing in \(corpus.name) mentions \(query).",
                        foundNothing: true)
                }
                let lines = hits.map { "\($0.title): …\($0.snippet)…" }
                return SkillOutcome(
                    ok: true,
                    summary: "\(hits.count) in \(corpus.name):\n"
                        + lines.joined(separator: "\n"),
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    private var corpusProgress: SkillBinding {
        SkillBinding(
            name: "corpus_progress",
            description: """
            Say how big a writing project or code repository is — its \
            documents or files, and word count.
            """,
            parameters: [Self.projectParameter],
            access: .read,
            backing: .native { arguments, _ in
                let corpus: OpenCorpus
                switch project(arguments["project"]) {
                case .corpus(let found): corpus = found
                case .refused(let outcome): return outcome
                }
                let items: [ProjectCorpusReader.Item]
                switch outline(corpus) {
                case .items(let found): items = found
                case .refused(let outcome): return outcome
                }

                let flat = items.flatMap(\.flattened)
                let documents = flat.filter { !$0.isContainer }
                var words = 0
                var written = 0
                for item in documents {
                    guard case .success(let text) = ProjectCorpusReader.text(
                        itemID: item.id, projectRoot: corpus.projectRoot,
                        structure: corpus.structure) else { continue }
                    let count = text.split(whereSeparator: \.isWhitespace).count
                    words += count
                    if count > 0 { written += 1 }
                }
                return SkillOutcome(
                    ok: true,
                    summary: """
                    \(corpus.name): \(words.formatted()) words across \(written) of \
                    \(documents.count) documents, in \(flat.count - documents.count) folders.
                    """,
                    archivePolicy: .stateSnapshot,
                    adapterTrail: [AdapterID.normalized(name)])
            })
    }

    // MARK: - Finding one item

    enum Located {
        case one(ProjectCorpusReader.Item)
        case many([ProjectCorpusReader.Item])
        case none
    }

    /// Exact title, then containment. Ambiguity refuses — manuscripts repeat titles.
    static func locate(_ wanted: String, in items: [ProjectCorpusReader.Item]) -> Located {
        let needle = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return .none }
        let exact = items.filter { $0.title.lowercased() == needle }
        if exact.count == 1 { return .one(exact[0]) }
        if exact.count > 1 { return .many(exact) }
        let contained = items.filter { $0.title.lowercased().contains(needle) }
        if contained.count == 1 { return .one(contained[0]) }
        if contained.count > 1 { return .many(contained) }
        return .none
    }

    static let spokenLimit = 40
    static let searchLimit = 12

    /// A few words either side of a hit, on one line.
    static func snippet(_ text: String, around range: Range<String.Index>, span: Int = 60) -> String {
        let start = text.index(
            range.lowerBound, offsetBy: -span, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(
            range.upperBound, offsetBy: span, limitedBy: text.endIndex) ?? text.endIndex
        return text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

//
//  DocumentCorpusAdapter.swift
//  MaryPlugin
//
//  READING A WRITING PROJECT, AND CHANGING ITS SHAPE THROUGH ITS OWN MENUS.
//
//  The compiled half of the document-corpus lane. Every value it hands back —
//  an outline, a chapter's text, a search result, a word count — has to come
//  from somewhere that can RETURN one, and a managed-UI recipe returns
//  nothing; that structural limit is why this exists rather than a recipe.
//
//  NOTHING HERE NAMES AN APPLICATION. Element names, path templates, menu
//  paths and the project extension all arrive from
//  `PluginCorpusStructureSchema`. A second writing application that keeps its
//  project as a directory is a `.mary` file.
//
//  ⚠️ THE READS COME FROM DISK AND THE CHANGES GO THROUGH THE MENUS, and the
//  asymmetry is the whole safety argument. An editor with the project open
//  autosaves on its own schedule: a write from outside races that save and
//  loses silently, so Mary never writes into the project. She reads it —
//  which is safe, and stale by at most one autosave — and asks the
//  application to make changes, which is slower and cannot lose work.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation

public struct DocumentCorpusAdapter: MaryAdapter {

    public let name = "document-corpus"
    public let summary =
        "reads a writing project's outline and text, and changes its shape through its own menus"

    /// NO APPLICATION IDENTITY, deliberately — this is an observation adapter
    /// serving whichever applications declare a corpus, and claiming one
    /// would collide with the package that legitimately owns it.
    public let applicationIdentifiers: Set<String> = []
    public let abilities: Set<AbilityID> = [.writing]

    public init() {}

    public var skillBindings: [SkillBinding] {
        [readOutline, readDocument, searchCorpus, corpusProgress]
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
                capabilities: [capability],
                inputTypes: [input], outputTypes: [output],
                observesPerceptions: ["perception.document-corpus"],
                targetClasses: ["writing-project"])
        }
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Document Corpus",
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
            ],
            providesPerceptions: ["perception.document-corpus"],
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
        switch DocumentCorpusSupport.resolve(named) {
        case .success(let corpus): return .corpus(corpus)
        case .failure(let refusal):
            return .refused(SkillOutcome(ok: false, summary: refusal.spoken))
        }
    }

    /// The same two-case shape `Resolved` uses, and for the same reason: the
    /// failure here is a SENTENCE rather than an error, composed where the
    /// project's name is in hand.
    enum Outlined {
        case items([DocumentCorpusReader.Item])
        case refused(SkillOutcome)
    }

    func outline(_ corpus: OpenCorpus) -> Outlined {
        switch DocumentCorpusReader.outline(
            projectRoot: corpus.projectRoot, structure: corpus.structure) {
        case .success(let items): return .items(items)
        case .failure(let failure):
            return .refused(SkillOutcome(ok: false, summary: failure.spoken))
        }
    }

    static let projectParameter = ModelSkillSchema.Parameter(
        name: "project", type: "string",
        description: "Which project. Omit when only one is open.",
        required: false)

    // MARK: - Reading

    private var readOutline: SkillBinding {
        SkillBinding(
            name: "read_corpus_outline",
            description: """
            Read a writing project's outline — its folders and documents, in \
            order, as the binder shows them.
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
                let items: [DocumentCorpusReader.Item]
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
            description: "Read one document's text out of a writing project, by its title.",
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
                let items: [DocumentCorpusReader.Item]
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
                    // A MANUSCRIPT REPEATS ITS TITLES — every act has a
                    // "Chapter 1". Naming the rivals with their parent is the
                    // only useful refusal, and picking one would silently
                    // read the wrong chapter.
                    return SkillOutcome(
                        ok: false,
                        summary: "\(corpus.name) has \(rivals.count) documents called "
                            + "\(wanted). Say which folder it's in.")
                case .one(let item):
                    switch DocumentCorpusReader.text(
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
            description: "Find which documents in a writing project mention a word or phrase.",
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
                let items: [DocumentCorpusReader.Item]
                switch outline(corpus) {
                case .items(let found): items = found
                case .refused(let outcome): return outcome
                }

                // A WALK AND A SCAN, not an index. The application keeps its
                // own search index, and reading somebody else's index format
                // is a bet on it not changing; a manuscript is small enough
                // that reading it is cheap and always current.
                var hits: [(title: String, snippet: String)] = []
                for item in items.flatMap(\.flattened) where !item.isContainer {
                    guard hits.count < Self.searchLimit else { break }
                    guard case .success(let text) = DocumentCorpusReader.text(
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
            description: "Say how big a writing project is — its documents and word count.",
            parameters: [Self.projectParameter],
            access: .read,
            backing: .native { arguments, _ in
                let corpus: OpenCorpus
                switch project(arguments["project"]) {
                case .corpus(let found): corpus = found
                case .refused(let outcome): return outcome
                }
                let items: [DocumentCorpusReader.Item]
                switch outline(corpus) {
                case .items(let found): items = found
                case .refused(let outcome): return outcome
                }

                let flat = items.flatMap(\.flattened)
                let documents = flat.filter { !$0.isContainer }
                var words = 0
                var written = 0
                for item in documents {
                    guard case .success(let text) = DocumentCorpusReader.text(
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
        case one(DocumentCorpusReader.Item)
        case many([DocumentCorpusReader.Item])
        case none
    }

    /// Exact title, then containment, and AMBIGUITY REFUSES. A manuscript
    /// repeats its titles by design — every act has a "Chapter 1" — so
    /// picking the first match would read a different chapter than the one
    /// asked for, confidently and without any sign.
    static func locate(_ wanted: String, in items: [DocumentCorpusReader.Item]) -> Located {
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

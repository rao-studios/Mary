//
//  CorpusCrawl.swift
//  MaryPlugin
//
//  THE NEIGHBOURHOOD WALK: from the file the user settled on, outward through
//  the edges that actually mean something, and no further.
//
//  THE REACH IS "NEIGHBOURS PLUS ANCESTRY", and the asymmetry is the whole
//  design. Everything the focused file references is worth one hop — those are
//  the files you are working among. Only ancestry is worth a second, because a
//  base type or a protocol is where the SEMANTICS of a subtype live, while a
//  second hop through ordinary references would drag in half the project and
//  make "related" mean nothing.
//
//  CAPS ARE NOT A SAFETY NET HERE, THEY ARE THE FEATURE. A crawl that returned
//  sixty files would be a worse answer than one that returns eight, no matter
//  how much of it was true.
//
//  STRUCTURE ONLY, DELIBERATELY. The crawl says what exists and what points
//  at what; whether a file's contents are evidence of how the USER writes is a
//  different question with a different answer — the edit may be a checkout, or
//  older than this session, or not theirs. The observer above holds that gate,
//  because it is the only layer that knows when the edit happened. A version
//  of this function took a `priorFocusedHash` for the purpose and then used it
//  in neither branch of the expression it appeared in.
//
//  NOTHING HERE NAMES A LANGUAGE. What a reference looks like, what an
//  ancestry looks like, what a declaration looks like and which files are
//  units at all arrive as declared patterns. The walk is the part that is the
//  same for every notation: resolve, hop, bound, stop.
//

import Foundation
import MaryAmbient
import os
import MaryFoundation

/// Which files declare which names, for one project.
///
/// A REFERENCE IS A NAME, AND A NAME IS NOT A FILE. The crawl's whole job is
/// turning the first into the second, and this index is the only thing that
/// can: without it a reference is a string that matches nothing and the walk
/// stops after zero hops, which looks exactly like a file that touches nothing.
public struct CorpusTypeIndex: Sendable {
    /// Declared name → project-relative path of the file declaring it.
    public private(set) var declaringFile: [String: String] = [:]
    public let root: String

    public init(root: String, files: [(relativePath: String, declaredNames: [String])]) {
        self.root = root
        for file in files {
            for name in file.declaredNames where declaringFile[name] == nil {
                // FIRST DECLARATION WINS, deterministically, because the file
                // list is walked in sorted order. Two files declaring one name
                // is a project that will not build; picking arbitrarily
                // between them would make the crawl differ between runs.
                declaringFile[name] = file.relativePath
            }
        }
    }

    public func file(declaring name: String) -> String? { declaringFile[name] }
}

/// The type index, kept between crawls.
///
/// WITHOUT THIS THE OBSERVER IS UNUSABLE, and the arithmetic is the argument:
/// building an index means reading and pattern-matching EVERY unit in the
/// project — around seven hundred files for the checkout this was written in —
/// and settling on a new file is a thing a person does every few seconds. Paid
/// per settle, the corpus would burn more CPU indexing than the editor uses
/// compiling.
///
/// A SHORT TTL RATHER THAN INVALIDATION. The index maps declared names to
/// files, so it goes stale only when a type is ADDED, REMOVED or RENAMED —
/// rare next to ordinary editing, and the cost of being briefly wrong is one
/// neighbour missing from one crawl until the window passes. Watching the
/// filesystem to be exactly right would be a second observer, with its own
/// wakeups, to avoid an error that corrects itself in a minute.
public final class CorpusTypeIndexCache: @unchecked Sendable {

    public static let shared = CorpusTypeIndexCache()

    public static let lifetime: TimeInterval = 60

    private let box = OSAllocatedUnfairLock<[String: (index: CorpusTypeIndex, built: Date)]>(
        initialState: [:])

    public init() {}

    public func index(
        root: String, corpus: PluginCorpusSchema, at now: Date = Date(),
        build: () -> CorpusTypeIndex
    ) -> CorpusTypeIndex {
        if let cached = box.withLock({ $0[root] }),
           now.timeIntervalSince(cached.built) < Self.lifetime {
            return cached.index
        }
        let built = build()
        box.withLock { $0[root] = (built, now) }
        return built
    }

    /// Drop a project's index — the pane's re-index action, and anything else
    /// that knows the shape changed.
    public func forget(root: String) {
        box.withLock { $0[root] = nil }
    }

    public func forgetAll() {
        box.withLock { $0 = [:] }
    }
}

public enum CorpusCrawl {

    /// One file, read and measured, before it becomes a unit.
    public struct Read: Sendable {
        public let relativePath: String
        public let absolutePath: String
        public let text: CorpusText
        public let declaredNames: [String]
        public let references: [String]
        public let ancestry: [String]
        public let contentHash: String
    }

    // MARK: - Reading the project

    /// Every file in the project a corpus claims as a unit.
    ///
    /// The exclusions are declared, and they matter for cost as much as
    /// correctness: a walk through build products reads thousands of generated
    /// files to learn nothing about how a person writes.
    public static func projectFiles(
        root: String, corpus: PluginCorpusSchema
    ) -> [String] {
        // SYMLINKS RESOLVED ON BOTH SIDES, or the prefix never matches. A
        // root under `/tmp` or `/var` is reached as `/private/...` by the
        // enumerator, so every path came back ABSOLUTE from the relative-path
        // helper below — and a unit addressed absolutely is machine-local,
        // which is the one thing the addressing scheme may not be. Found by
        // the crawl tests, whose scratch tree lives in exactly such a place;
        // a user's symlinked checkout would have hit it identically.
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath()
        let excluded = Set(corpus.exclude)
        let included = Set(corpus.include)
        guard let walker = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [String] = []
        for case let url as URL in walker {
            if excluded.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard included.contains(url.pathExtension) else { continue }
            found.append(relativePath(of: url.path, under: rootURL.path))
        }
        return found.sorted()
    }

    public static func relativePath(of absolute: String, under root: String) -> String {
        func strip(_ path: String, _ base: String) -> String? {
            let prefixed = base.hasSuffix("/") ? base : base + "/"
            guard path.hasPrefix(prefixed) else { return nil }
            return String(path.dropFirst(prefixed.count))
        }
        if let direct = strip(absolute, root) { return direct }
        // The symlink retry — see `projectFiles`. Done second because it costs
        // two filesystem round trips and almost never runs.
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let resolvedPath = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
        return strip(resolvedPath, resolvedRoot) ?? absolute
    }

    /// Read one file and pull everything the declarations ask for.
    ///
    /// Nil when the file is unreadable or past its declared size cap. A
    /// generated source is not what "how this person works" is made of, and
    /// reading a 10 MB file to find that out is the expensive way to learn it.
    public static func read(
        relativePath: String, root: String, corpus: PluginCorpusSchema
    ) -> Read? {
        let absolute = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent(relativePath).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: absolute),
              let size = attributes[.size] as? Int,
              size <= corpus.budgets.maximumFileBytes,
              let source = try? String(contentsOfFile: absolute, encoding: .utf8)
        else { return nil }

        let text = CorpusText(
            source: source,
            filename: (relativePath as NSString).lastPathComponent)
        return Read(
            relativePath: relativePath,
            absolutePath: absolute,
            text: text,
            declaredNames: corpus.relations.declarations.flatMap {
                CorpusPatterns.captures($0, in: text.code)
            },
            references: corpus.relations.references.flatMap {
                CorpusPatterns.captures($0, in: text.code)
            },
            // A CLAUSE, THEN SPLIT. One `: A, B<C>` captures as a single
            // string; the names inside it are what the walk needs.
            ancestry: corpus.relations.ancestry
                .flatMap { CorpusPatterns.captures($0, in: text.code) }
                .flatMap(names(inClause:)),
            contentHash: UnitIndexHashing.stableHash(source))
    }

    /// Split an inheritance clause into the names it lists, dropping generic
    /// arguments and module qualifiers.
    static func names(inClause clause: String) -> [String] {
        clause
            .split(whereSeparator: { $0 == "," })
            .compactMap { part in
                let head = part
                    .split(whereSeparator: { $0 == "<" })
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // `Module.Protocol` names the protocol; the qualifier is not a
                // declared name anywhere in the project.
                let bare = head?.split(separator: ".").last.map(String.init)
                guard let bare, !bare.isEmpty,
                      bare.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                else { return nil }
                return bare
            }
    }

    // MARK: - The walk

    /// Walk from `focusedPath`, returning one unit per visited file.
    ///
    /// Returns [] when the focused file is unreadable, is not a unit of this
    /// corpus, or sits outside the project — every one of which is an ordinary
    /// condition rather than an error, and none worth a spoken word.
    public static func crawl(
        focusedPath: String,
        root: String,
        projectName: String,
        corpus: PluginCorpusSchema,
        index: CorpusTypeIndex,
        applicationID: String,
        at now: Date = Date()
    ) -> [IndexedUnit] {
        let focusedRelative = relativePath(of: focusedPath, under: root)
        guard corpus.include.contains((focusedRelative as NSString).pathExtension),
              let focused = read(relativePath: focusedRelative, root: root, corpus: corpus)
        else { return [] }

        var visited: [String: Read] = [focusedRelative: focused]
        var order: [String] = [focusedRelative]
        var depth: [String: Int] = [focusedRelative: 0]
        var queue: [(read: Read, depth: Int)] = [(focused, 0)]

        while !queue.isEmpty, order.count < corpus.budgets.maximumFiles {
            let (current, currentDepth) = queue.removeFirst()
            // DEPTH 1 IS AS FAR AS AN ORDINARY REFERENCE REACHES; ancestry
            // gets the second hop, and nothing gets a third.
            let hops: [String] = currentDepth == 0
                ? current.references + current.ancestry
                : current.ancestry
            guard currentDepth < 2 else { continue }

            for name in hops {
                guard order.count < corpus.budgets.maximumFiles else { break }
                guard let path = index.file(declaring: name),
                      path != current.relativePath,
                      visited[path] == nil,
                      let neighbour = read(relativePath: path, root: root, corpus: corpus)
                else { continue }
                visited[path] = neighbour
                order.append(path)
                depth[path] = currentDepth + 1
                queue.append((neighbour, currentDepth + 1))
            }
        }

        var edgeBudget = corpus.budgets.maximumEdges
        return order.compactMap { path -> IndexedUnit? in
            guard let read = visited[path] else { return nil }
            var relations: [UnitRelation] = []
            for name in read.ancestry where edgeBudget > 0 {
                guard let target = index.file(declaring: name) else { continue }
                relations.append(UnitRelation(
                    subject: read.relativePath, predicate: .inheritsFrom, object: target))
                edgeBudget -= 1
            }
            for name in Set(read.references) where edgeBudget > 0 {
                guard let target = index.file(declaring: name), target != read.relativePath
                else { continue }
                // `holds` is the vocabulary's word for an ordinary
                // dependency — the depth-1 edge, as distinct from ancestry.
                relations.append(UnitRelation(
                    subject: read.relativePath, predicate: .holds, object: target))
                edgeBudget -= 1
            }

            return IndexedUnit(
                subject: DepositSubject(
                    app: applicationID,
                    documentIdentity: read.relativePath,
                    projectIdentity: root,
                    contentKind: .document,
                    capturedAt: now),
                projectName: projectName,
                relativePath: read.relativePath,
                contentHash: read.contentHash,
                declaredTypes: read.declaredNames,
                relations: relations,
                apiHeaders: [],
                neighbours: relations.map(\.object),
                capturedAt: now)
        }
    }
}

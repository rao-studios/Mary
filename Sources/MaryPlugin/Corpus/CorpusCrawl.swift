//
//  CorpusCrawl.swift
//  MaryPlugin
//
//  WHAT: Neighbourhood walk from the settled file — neighbours plus ancestry.
//  IN:   CorpusObserver / declared patterns
//  OUT:  units (structure only — style gate lives on CorpusObserver)
//  PIN:  Caps are the feature. Language-agnostic: resolve, hop, bound, stop.
//        Ordinary refs: depth 1. Ancestry: one extra hop.
//

import Foundation
import MaryAmbient
import os
import MaryFoundation

/// Which files declare which names, for one project. A reference is a name; this maps it to a file.
public struct CorpusTypeIndex: Sendable {
    /// Declared name → project-relative path of the file declaring it.
    public private(set) var declaringFile: [String: String] = [:]
    public let root: String

    public init(root: String, files: [(relativePath: String, declaredNames: [String])]) {
        self.root = root
        for file in files {
            for name in file.declaredNames where declaringFile[name] == nil {
                // First declaration wins (files sorted). Two files, one name,
                // will not build; an arbitrary pick would make crawls differ.
                declaringFile[name] = file.relativePath
            }
        }
    }

    public func file(declaring name: String) -> String? { declaringFile[name] }
}

/// Type index kept between crawls. Short TTL rather than invalidation.
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

    /// Drop a project's index — pane re-index, or anything that knows the shape changed.
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

    /// Every file a corpus claims as a unit. Exclusions skip generated trees.
    public static func projectFiles(
        root: String, corpus: PluginCorpusSchema
    ) -> [String] {
        // Resolve both sides or the prefix never matches (`/tmp` → `/private/...`).
        // Absolute unit paths are machine-local.
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
        // Symlink retry — see `projectFiles`. Second because it almost never runs.
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let resolvedPath = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
        return strip(resolvedPath, resolvedRoot) ?? absolute
    }

    /// Read one file for the declared probes. Nil if unreadable or past size cap.
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
            // Clause then split: `: A, B<C>` is one capture; the walk needs the names.
            ancestry: corpus.relations.ancestry
                .flatMap { CorpusPatterns.captures($0, in: text.code) }
                .flatMap(names(inClause:)),
            contentHash: UnitIndexHashing.stableHash(source))
    }

    /// Split an inheritance clause into names, dropping generics and module qualifiers.
    static func names(inClause clause: String) -> [String] {
        clause
            .split(whereSeparator: { $0 == "," })
            .compactMap { part in
                let head = part
                    .split(whereSeparator: { $0 == "<" })
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // `Module.Protocol` names the protocol; the qualifier is not a declared name.
                let bare = head?.split(separator: ".").last.map(String.init)
                guard let bare, !bare.isEmpty,
                      bare.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                else { return nil }
                return bare
            }
    }

    // MARK: - The walk

    /// Walk from `focusedPath`. [] if unreadable, not a unit, or outside the project.
    public static func crawl(
        focusedPath: String,
        root: String,
        projectName: String,
        corpus: PluginCorpusSchema,
        index: CorpusTypeIndex,
        applicationID: String,
        at now: Date = Date(),
        discipline: AbilityID? = nil
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
            // Ordinary refs: depth 1. Ancestry: one extra hop. Nothing gets a third.
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
                // `holds` is the depth-1 edge, as distinct from ancestry.
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
                apiHeaders: headers(from: read, declarations: corpus.relations.declarations),
                neighbours: relations.map(\.object),
                doc: leadingDoc(in: read.text),
                capturedAt: now,
                discipline: discipline)
        }
    }

    /// Declaration lines for the annotator (Public API) and neighbourhood digest.
    /// PIN: empty headers left the summariser with names only.
    static func headers(
        from read: Read, declarations: [String], limit: Int = 20
    ) -> [String] {
        let lines = read.text.source.split(
            separator: "\n", omittingEmptySubsequences: false)
        var seen: Set<String> = []
        var headers: [String] = []
        for pattern in declarations {
            for capture in CorpusPatterns.capturesWithLines(pattern, in: read.text.code) {
                let index = capture.line - 1
                guard index >= 0, index < lines.count else { continue }
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, seen.insert(line).inserted else { continue }
                headers.append(line)
                if headers.count >= limit { return headers }
            }
        }
        return headers
    }

    /// First comment paragraph after the filename/module banner. Nil rather than a short leftover.
    static func leadingDoc(in text: CorpusText, limit: Int = 400) -> String? {
        let lines = text.comments.split(
            separator: "\n", omittingEmptySubsequences: false)
        var collected: [String] = []
        var banner = 0
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let stripped = trimmed.drop {
                $0 == "/" || $0 == "*" || $0.isWhitespace
            }
            let line = String(stripped)
            if line.isEmpty {
                if collected.isEmpty {
                    banner += 1
                    continue
                }
                break
            }
            if collected.isEmpty, banner < 6 {
                let isBanner = line.hasSuffix(".swift")
                    || line.hasSuffix(".m")
                    || !line.contains(" ")
                    || line.hasPrefix("Created by")
                    || line.hasPrefix("Copyright")
                if isBanner {
                    banner += 1
                    continue
                }
            }
            collected.append(line)
            if collected.joined(separator: " ").count >= limit { break }
        }
        let joined = collected.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count >= 20 else { return nil }
        return joined.count > limit
            ? String(joined.prefix(limit)) + "…"
            : joined
    }
}

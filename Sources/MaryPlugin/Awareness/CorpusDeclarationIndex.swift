//
//  CorpusDeclarationIndex.swift
//  MaryPlugin
//
//  WHAT: Every declaration in a project, with the file and line it is on.
//  IN:   the corpus' own declared `relations.declarations` grammar
//  OUT:  CorpusTracer / EnclosingUnit / AwarenessObserver
//  PIN:  EVERY declaration, not the first. `CorpusTypeIndex` answers "which
//        file declares this name" and keeps one winner on purpose — a crawl
//        that hopped twice to the same name would double back. Tracing asks
//        the opposite question and has to see the rivals, so this is a second
//        index rather than a change to that one.
//

import Foundation
import MaryFoundation
import os

public struct CorpusDeclarationIndex: Sendable {

    /// One declaration, where it is, and how its own line reads.
    public struct Declaration: Sendable, Equatable {
        public let name: String
        public let relativePath: String
        /// 1-based, as a person counts lines.
        public let line: Int
        /// The declaration's own line, trimmed — "func parameters() -> [String] {".
        public let header: String

        public init(name: String, relativePath: String, line: Int, header: String) {
            self.name = name
            self.relativePath = relativePath
            self.line = line
            self.header = header
        }
    }

    public let root: String
    /// Whether every file the corpus claims was actually read.
    ///
    /// A PARTIAL INDEX IS STILL TRUE ABOUT WHAT IT FOUND, and false about
    /// what it did not: every hit is real, and "nothing reaches this" is a
    /// claim it has not earned. Callers must not turn its silence into an
    /// answer — see `AwarenessBrief.standing`.
    public let isComplete: Bool
    private let byName: [String: [Declaration]]
    private let byPath: [String: [Declaration]]

    public init(root: String, declarations: [Declaration], isComplete: Bool = true) {
        self.root = root
        self.isComplete = isComplete
        byName = Dictionary(grouping: declarations, by: \.name)
        byPath = Dictionary(grouping: declarations, by: \.relativePath)
    }

    /// Every place this name is declared, in project order.
    public func declarations(named name: String) -> [Declaration] {
        byName[name] ?? []
    }

    /// Whether the project declares this name at all — the gate that keeps a
    /// trace to the user's own code instead of the standard library.
    public func declares(_ name: String) -> Bool {
        byName[name] != nil
    }

    /// The declaration a line sits inside, by position: the last one at or
    /// above it in the same file.
    ///
    /// APPROXIMATE BY CONSTRUCTION, and it says so where it is spoken: a
    /// regex grammar knows where declarations START and never where they end,
    /// so the answer is "the declaration this line follows", which is right
    /// for a call site and wrong only for a line after a declaration's close.
    public func nearest(in relativePath: String, line: Int) -> Declaration? {
        byPath[relativePath]?
            .filter { $0.line <= line }
            .max { $0.line < $1.line }
    }

    public var count: Int { byName.values.reduce(0) { $0 + $1.count } }
}

/// Declaration indexes kept between traces. Short TTL rather than
/// invalidation — `CorpusTypeIndexCache`'s own choice, for its own reason: a
/// name you just typed should become traceable on its own, without a signal.
public final class CorpusDeclarationIndexCache: @unchecked Sendable {

    public static let shared = CorpusDeclarationIndexCache()

    public static let lifetime: TimeInterval = CorpusTypeIndexCache.lifetime

    private let box = OSAllocatedUnfairLock<[String: (index: CorpusDeclarationIndex, built: Date)]>(
        initialState: [:])

    public init() {}

    /// The index for a project, built if need be.
    ///
    /// `within` bounds a build that happens ON A TURN. Reading a large
    /// repository takes seconds the first time, and a turn cannot spend them:
    /// past the deadline the walk stops and says so, rather than blowing the
    /// pre-lane budget and costing the turn its whole awareness pass. A
    /// partial index is never cached, so the next build — usually the
    /// observer's, off the turn path and unbounded — completes it.
    public func index(
        root: String,
        corpus: PluginCorpusSchema,
        text: CorpusTextCache = .shared,
        at now: Date = Date(),
        within budget: TimeInterval? = nil
    ) -> CorpusDeclarationIndex {
        if let cached = box.withLock({ $0[root] }),
           now.timeIntervalSince(cached.built) < Self.lifetime {
            return cached.index
        }
        let built = Self.build(
            root: root, corpus: corpus, text: text, at: now, within: budget)
        guard built.isComplete else { return built }
        box.withLock { $0[root] = (built, now) }
        return built
    }

    static func build(
        root: String,
        corpus: PluginCorpusSchema,
        text: CorpusTextCache = .shared,
        at now: Date = Date(),
        within budget: TimeInterval? = nil
    ) -> CorpusDeclarationIndex {
        let deadline = budget.map { DispatchTime.now() + $0 }
        var declarations: [CorpusDeclarationIndex.Declaration] = []
        var complete = true
        for relativePath in text.files(root: root, corpus: corpus, at: now) {
            if let deadline, DispatchTime.now() > deadline {
                complete = false
                break
            }
            guard let source = text.text(
                relativePath: relativePath, root: root, corpus: corpus, at: now)
            else { continue }
            declarations.append(contentsOf: Self.declarations(
                in: source, relativePath: relativePath, corpus: corpus))
        }
        return CorpusDeclarationIndex(
            root: root, declarations: declarations, isComplete: complete)
    }

    /// The declared grammar, run over the code slice, with each capture's own
    /// line pulled from the source so the header reads as it was written.
    static func declarations(
        in text: CorpusText,
        relativePath: String,
        corpus: PluginCorpusSchema
    ) -> [CorpusDeclarationIndex.Declaration] {
        let lines = text.source.split(
            separator: "\n", omittingEmptySubsequences: false)
        var seen = Set<String>()
        var found: [CorpusDeclarationIndex.Declaration] = []
        for pattern in corpus.relations.declarations {
            for capture in CorpusPatterns.capturesWithLines(pattern, in: text.code) {
                // One name per line: two grammars matching the same
                // declaration is a fact about the patterns, not the project.
                guard seen.insert("\(capture.name)|\(capture.line)").inserted else { continue }
                let index = capture.line - 1
                let header = index >= 0 && index < lines.count
                    ? lines[index].trimmingCharacters(in: .whitespaces)
                    : ""
                found.append(.init(
                    name: capture.name,
                    relativePath: relativePath,
                    line: capture.line,
                    header: header))
            }
        }
        return found.sorted { $0.line < $1.line }
    }

    public func forget(root: String) {
        box.withLock { $0[root] = nil }
    }

    public func forgetAll() {
        box.withLock { $0 = [:] }
    }
}

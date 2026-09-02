//
//  CorpusTextCache.swift
//  MaryPlugin
//
//  WHAT: Files read for tracing, kept between traces and validated by mtime.
//  IN:   CorpusCrawl.projectFiles / .read
//  OUT:  CorpusDeclarationIndex / CorpusTracer
//  PIN:  A body is never served stale — the file's own modification date is
//        the gate, not a clock. The FILE LIST is the only thing on a timer,
//        because walking a tree is what costs, and a file appearing is not a
//        file changing.
//

import Foundation
import MaryFoundation
import os

public final class CorpusTextCache: @unchecked Sendable {

    public static let shared = CorpusTextCache()

    /// The walk, not the words. Same window `CorpusTypeIndexCache` settled on.
    public static let listingLifetime: TimeInterval = CorpusTypeIndexCache.lifetime

    /// Everything held across every project. Past it the coldest entries go —
    /// tracing a repository must not become a way to hold one in memory.
    public static let totalCharacterCap = 12_000_000

    private struct Entry {
        var text: CorpusText
        var modified: Date
        var touchedAt: Date
        var characters: Int
    }

    private let listings = OSAllocatedUnfairLock<[String: (files: [String], built: Date)]>(
        initialState: [:])
    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    public init() {}

    /// Every file this corpus claims, from the last walk or a fresh one.
    public func files(
        root: String, corpus: PluginCorpusSchema, at now: Date = Date()
    ) -> [String] {
        if let cached = listings.withLock({ $0[root] }),
           now.timeIntervalSince(cached.built) < Self.listingLifetime {
            return cached.files
        }
        let walked = CorpusCrawl.projectFiles(root: root, corpus: corpus)
        listings.withLock { $0[root] = (walked, now) }
        return walked
    }

    /// One file, split into its code and comment slices once. Nil when it
    /// cannot be read, or is past the corpus' declared size cap.
    ///
    /// THE SLICES, NOT `CorpusCrawl.Read`. That type also runs the
    /// declarations, references and ancestry grammars over every file it
    /// touches — three regex sets the crawl needs and tracing does not. Over
    /// this repository that was most of a two-and-a-half second index build,
    /// two thirds of it for answers nobody read, and the declarations grammar
    /// then ran a second time on top.
    public func text(
        relativePath: String, root: String, corpus: PluginCorpusSchema,
        at now: Date = Date()
    ) -> CorpusText? {
        let key = "\(root)|\(relativePath)"
        let absolute = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent(relativePath).path
        let attributes = try? FileManager.default.attributesOfItem(atPath: absolute)
        let modified = attributes?[.modificationDate] as? Date

        if let cached = entries.withLock({ $0[key] }), let modified,
           cached.modified == modified {
            entries.withLock { $0[key]?.touchedAt = now }
            return cached.text
        }
        guard let size = attributes?[.size] as? Int,
              size <= corpus.budgets.maximumFileBytes,
              let source = try? String(contentsOfFile: absolute, encoding: .utf8)
        else {
            entries.withLock { $0[key] = nil }
            return nil
        }
        let text = CorpusText(
            source: source,
            filename: (relativePath as NSString).lastPathComponent)
        guard let modified else { return text }
        entries.withLock {
            $0[key] = Entry(
                text: text, modified: modified, touchedAt: now,
                characters: source.count)
        }
        evictIfNeeded()
        return text
    }

    /// Coldest first, until the cap is honoured again.
    private func evictIfNeeded() {
        entries.withLock { held in
            var total = held.values.reduce(0) { $0 + $1.characters }
            guard total > Self.totalCharacterCap else { return }
            for key in held.keys.sorted(by: {
                (held[$0]?.touchedAt ?? .distantPast) < (held[$1]?.touchedAt ?? .distantPast)
            }) {
                guard total > Self.totalCharacterCap else { break }
                total -= held[key]?.characters ?? 0
                held[key] = nil
            }
        }
    }

    /// Drop one project — a re-index, or anything that knows the tree changed.
    public func forget(root: String) {
        listings.withLock { $0[root] = nil }
        entries.withLock { held in
            for key in held.keys where key.hasPrefix("\(root)|") { held[key] = nil }
        }
    }

    public func forgetAll() {
        listings.withLock { $0 = [:] }
        entries.withLock { $0 = [:] }
    }
}

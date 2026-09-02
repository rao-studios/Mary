//
//  RoutingExemplarStore.swift
//  MaryBrain
//
//  WHAT: Settled (query, skill, intent, ok) vectors that move later distances.
//  IN:   confidence dispatch / lane outcomes
//  OUT:  extra positives/negatives for intent and skill search
//  PIN:  Recency cap; a bad night must not pin a centroid.
//

import MaryAmbient
import MaryFoundation
import Foundation
import os

public struct RoutingExemplar: Sendable, Codable, Equatable {
    public var query: String
    public var skillID: String
    public var intent: String
    public var ok: Bool
    public var storedAt: Date

    public init(
        query: String,
        skillID: String,
        intent: String,
        ok: Bool,
        storedAt: Date = Date()
    ) {
        self.query = query
        self.skillID = skillID
        self.intent = intent
        self.ok = ok
        self.storedAt = storedAt
    }
}

public final class RoutingExemplarStore: @unchecked Sendable {

    public static let shared = RoutingExemplarStore(persist: true)

    public static let perSkillCap = 24
    public static let totalCap = 200
    public static let horizon: TimeInterval = 30 * 24 * 60 * 60

    private let box = OSAllocatedUnfairLock<[RoutingExemplar]>(initialState: [])
    private let persist: Bool
    private let url: URL?

    /// The store, pre-grouped the way its two readers actually ask —
    /// recency-sorted query lists per skill and per intent, split by `ok`.
    ///
    /// `queries(...)` used to copy, prune and sort the WHOLE array on every
    /// call, and `SemanticSkillRequestIndex.affinities` calls it twice per
    /// Skill entry per turn — dozens of full copies to answer questions whose
    /// shape never changes between records. Rebuilt lazily; invalidated by
    /// `record()`/`load()`, and by age so the 30-day horizon stays honest
    /// inside a long-running session.
    private struct Derived {
        var bySkill: [String: [String]]   // key "\(skillID)|\(ok)"
        var byIntent: [String: [String]]  // key "\(intent)|\(ok)"
        var builtAt: Date
    }
    private let derivedBox = OSAllocatedUnfairLock<Derived?>(initialState: nil)
    private static let derivedStaleness: TimeInterval = 60 * 60

    public init(persist: Bool = false) {
        self.persist = persist
        if persist {
            let root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("Mary", isDirectory: true)
            if let root {
                try? FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true)
                url = root.appendingPathComponent("routing-exemplars.json")
            } else {
                url = nil
            }
            load()
        } else {
            url = nil
        }
    }

    public func all() -> [RoutingExemplar] {
        prune(box.withLock { $0 })
    }

    public func record(_ exemplar: RoutingExemplar) {
        let survivors = box.withLock { items in
            items.append(exemplar)
            items = Self.capped(prune(items))
            return items
        }
        derivedBox.withLock { $0 = nil }
        // A row evicted by the caps must not keep a warm vector — without this
        // the memo grew append-only with every distinct query ever recorded,
        // long past the rows themselves.
        let live = Set(survivors.map { RoutingQuery.firstLine($0.query) })
        vectorCache.withLock { cache in
            cache = cache.filter { live.contains($0.key) }
        }
        save()
    }

    public func queries(skillID: String, ok: Bool) -> [String] {
        derived().bySkill["\(skillID)|\(ok)"] ?? []
    }

    public func queries(intent: String, ok: Bool) -> [String] {
        derived().byIntent["\(intent)|\(ok)"] ?? []
    }

    private func derived() -> Derived {
        if let ready = derivedBox.withLock({ $0 }),
           Date().timeIntervalSince(ready.builtAt) < Self.derivedStaleness {
            return ready
        }
        let rows = all().sorted { $0.storedAt > $1.storedAt }
        var bySkill: [String: [String]] = [:]
        var byIntent: [String: [String]] = [:]
        for row in rows {
            bySkill["\(row.skillID)|\(row.ok)", default: []].append(row.query)
            byIntent["\(row.intent)|\(row.ok)", default: []].append(row.query)
        }
        let built = Derived(bySkill: bySkill, byIntent: byIntent, builtAt: Date())
        derivedBox.withLock { $0 = built }
        return built
    }

    /// Normalized vectors, memoized by FIRST LINE — `classify`/`affinities`
    /// consult exemplars on every call, and re-vectorizing the same settled
    /// sentence every turn is pure waste once it has been seen once.
    /// Pruned in `record()` to the surviving rows.
    ///
    /// FIRST LINE, because that is what every consumer scores. Rows recorded
    /// before the recording fix carry the composed multi-line routing query —
    /// the shape `RoutingQuery` itself documents as measurably diluted — so
    /// vectorizing them whole made the learning loop inert exactly when a
    /// world snapshot existed. Reading the first line restores those rows'
    /// effect without a migration.
    private let vectorCache = OSAllocatedUnfairLock<[String: [Float]]>(initialState: [:])

    private func normalizedVectors(
        for texts: [String], vectorizer: any UtteranceVectorizer
    ) -> [[Float]] {
        texts.compactMap { text -> [Float]? in
            let line = RoutingQuery.firstLine(text)
            if let cached = vectorCache.withLock({ $0[line] }) { return cached }
            guard let raw = vectorizer.vector(for: line) else { return nil }
            let normalized = AmbientVectorMath.normalized(raw)
            vectorCache.withLock { $0[line] = normalized }
            return normalized
        }
    }

    /// Settled positives/negatives for one Skill, already normalized.
    public func vectors(
        skillID: String, ok: Bool, vectorizer: any UtteranceVectorizer
    ) -> [[Float]] {
        normalizedVectors(for: queries(skillID: skillID, ok: ok), vectorizer: vectorizer)
    }

    /// Settled positives/negatives for one intent, already normalized.
    public func vectors(
        intent: String, ok: Bool, vectorizer: any UtteranceVectorizer
    ) -> [[Float]] {
        normalizedVectors(for: queries(intent: intent, ok: ok), vectorizer: vectorizer)
    }

    public var count: Int { all().count }

    /// Memo size, so a test can pin that it does not outlive its rows.
    public var cachedVectorCountForTesting: Int { vectorCache.withLock { $0.count } }

    private func prune(_ items: [RoutingExemplar]) -> [RoutingExemplar] {
        let cutoff = Date().addingTimeInterval(-Self.horizon)
        return items.filter { $0.storedAt >= cutoff }
    }

    private static func capped(_ items: [RoutingExemplar]) -> [RoutingExemplar] {
        var bySkill: [String: [RoutingExemplar]] = [:]
        for item in items.sorted(by: { $0.storedAt < $1.storedAt }) {
            var bucket = bySkill[item.skillID, default: []]
            bucket.append(item)
            if bucket.count > perSkillCap {
                bucket.removeFirst(bucket.count - perSkillCap)
            }
            bySkill[item.skillID] = bucket
        }
        var merged = bySkill.values.flatMap { $0 }
            .sorted { $0.storedAt < $1.storedAt }
        if merged.count > totalCap {
            merged.removeFirst(merged.count - totalCap)
        }
        return merged
    }

    private func load() {
        guard persist, let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([RoutingExemplar].self, from: data)
        else { return }
        box.withLock { $0 = Self.capped(prune(decoded)) }
        derivedBox.withLock { $0 = nil }
    }

    private func save() {
        guard persist, let url else { return }
        let items = all()
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

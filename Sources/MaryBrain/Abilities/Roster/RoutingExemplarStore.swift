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
        box.withLock { items in
            items.append(exemplar)
            items = Self.capped(prune(items))
        }
        save()
    }

    public func queries(skillID: String, ok: Bool) -> [String] {
        all()
            .filter { $0.skillID == skillID && $0.ok == ok }
            .sorted { $0.storedAt > $1.storedAt }
            .map(\.query)
    }

    public func queries(intent: String, ok: Bool) -> [String] {
        all()
            .filter { $0.intent == intent && $0.ok == ok }
            .sorted { $0.storedAt > $1.storedAt }
            .map(\.query)
    }

    /// Normalized vectors, memoized by query text — `classify`/`affinities`
    /// consult exemplars on every call, and re-vectorizing the same settled
    /// sentence every turn is pure waste once it has been seen once.
    /// Append-only: an evicted row's cache entry is simply never looked up
    /// again, not actively pruned — bounded in practice by the store's own
    /// per-skill/total caps.
    private let vectorCache = OSAllocatedUnfairLock<[String: [Float]]>(initialState: [:])

    private func normalizedVectors(
        for texts: [String], vectorizer: any UtteranceVectorizer
    ) -> [[Float]] {
        texts.compactMap { text -> [Float]? in
            if let cached = vectorCache.withLock({ $0[text] }) { return cached }
            guard let raw = vectorizer.vector(for: text) else { return nil }
            let normalized = AmbientVectorMath.normalized(raw)
            vectorCache.withLock { $0[text] = normalized }
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
    }

    private func save() {
        guard persist, let url else { return }
        let items = all()
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

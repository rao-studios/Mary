//
//  RoutingHabitStore.swift
//  MaryBrain
//
//  WHAT: This turn's view of settled (query, skill, intent) habits.
//  IN:   an async recall from `RoutingHabitMemory`, once per turn
//  OUT:  extra positives/negatives for intent and skill search
//  PIN:  A TURN-SCOPED VIEW, NOT A DATABASE. Durability moved to personal
//        Totem memory: a routing habit is how THIS user asks for things, so
//        it should follow them to another machine and be retrieved by
//        resemblance — neither of which a JSON file could do.
//        RETRIEVE, THEN SCORE LOCALLY. The backend ranked these in ITS
//        embedding space; every text here is re-vectorized in the space the
//        authored corpus lives in, because comparing two spaces against one
//        floor is wrong in a way nothing would report.
//        Recency cap; a bad night must not pin a centroid.
//

import MaryAmbient
import MaryFoundation
import Foundation
import os

public struct RoutingHabit: Sendable, Codable, Equatable {
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

public final class RoutingHabitStore: @unchecked Sendable {

    public static let shared = RoutingHabitStore()

    public static let perSkillCap = 24
    public static let totalCap = 200
    public static let horizon: TimeInterval = 30 * 24 * 60 * 60

    /// How many neighbours one recall asks for. The read is a turn-path
    /// round trip, and the consumers take a MAX over what comes back — past
    /// a handful, further neighbours cannot change the answer.
    public static let recallLimit = 24

    private let box = OSAllocatedUnfairLock<[RoutingHabit]>(initialState: [])

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

    /// `memory` is resolved per call rather than captured, so installing a
    /// backend after the shared store exists still takes effect.
    private let memoryOverride: (any RoutingHabitMemory)?

    public init(memory: (any RoutingHabitMemory)? = nil) {
        self.memoryOverride = memory
    }

    private var memory: any RoutingHabitMemory {
        memoryOverride ?? RoutingHabitMemoryProvider.current
    }

    // MARK: - The turn

    /// Ask personal memory what resembles this turn's words, and hold the
    /// answer for the synchronous readers below.
    ///
    /// ONE ROUND TRIP PER TURN. The old design read every stored row for every
    /// Skill and vectorized each — retrieval, re-implemented per turn against
    /// a file. Now the backend retrieves and this scores.
    public func recall(near utterance: String) async {
        let recalled = await memory.recall(near: utterance, limit: Self.recallLimit)
        let live = prune(recalled)
        box.withLock { $0 = live }
        derivedBox.withLock { $0 = nil }
        let keep = Set(live.map { RoutingQuery.firstLine($0.query) })
        vectorCache.withLock { cache in cache = cache.filter { keep.contains($0.key) } }
    }

    /// Drop this turn's recalled view. Nothing is lost — the habits live in
    /// personal memory, not here.
    public func clearRecall() {
        box.withLock { $0 = [] }
        derivedBox.withLock { $0 = nil }
    }

    public func all() -> [RoutingHabit] {
        prune(box.withLock { $0 })
    }

    /// Teach personal memory, and make the habit usable at once — a turn that
    /// dispatches twice should see the first habit on the second read.
    public func record(_ habit: RoutingHabit) {
        let live = box.withLock { items -> Set<String> in
            items.append(habit)
            items = Self.capped(prune(items))
            return Set(items.map { RoutingQuery.firstLine($0.query) })
        }
        derivedBox.withLock { $0 = nil }
        // The memo never outlives its rows, wherever the rows change.
        vectorCache.withLock { cache in cache = cache.filter { live.contains($0.key) } }
        let memory = self.memory
        // FIRE AND FORGET: a turn must never wait to be taught.
        Task.detached { await memory.remember(habit) }
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
    /// consult habits on every call, and re-vectorizing the same settled
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

    private func prune(_ items: [RoutingHabit]) -> [RoutingHabit] {
        let cutoff = Date().addingTimeInterval(-Self.horizon)
        return items.filter { $0.storedAt >= cutoff }
    }

    private static func capped(_ items: [RoutingHabit]) -> [RoutingHabit] {
        var bySkill: [String: [RoutingHabit]] = [:]
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

}

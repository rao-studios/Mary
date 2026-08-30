//
//  AmbientElementIndexStore.swift
//  MaryAmbient
//
//  WHAT: Where the per-scope indexes live. Worlds write; the reference gate reads snapshots.
//  IN:   noteElements at each world's write funnel
//  OUT:  AmbientReferenceGate / AffordanceProbe / AmbientAddressProbe
//  PIN:  Vectorization never happens under the lock. Last write wins.
//
import Foundation
import os

public final class AmbientElementIndexStore: @unchecked Sendable {

    public static let shared = AmbientElementIndexStore()

    /// Memoized embed-text → normalized vector. Names and kinds barely
    /// change between polls, so steady-state rebuilds vectorize nothing.
    private static let cacheCapacity = 512

    private struct State: Sendable {
        var vectorizer: (any AmbientTextVectorizer)?
        var indexes: [AmbientElementScope: AmbientElementIndex] = [:]
        /// When each scope last published. `noteElements` replaces wholesale but nothing here
        /// expires, so without a stamp a browser that quit an hour ago would keep answering — and a
        /// stale index is a confidently wrong referent, worse than none.
        var notedAt: [AmbientElementScope: Date] = [:]
        var vectorCache: [String: [Float]] = [:]
        /// Insertion-ordered keys for cheap oldest-first eviction.
        var cacheOrder: [String] = []
    }

    private let box: OSAllocatedUnfairLock<State>

    public init(vectorizer: (any AmbientTextVectorizer)? = nil) {
        box = OSAllocatedUnfairLock(initialState: State(vectorizer: vectorizer))
    }

    /// Production wiring for `.shared`; nil switches every scope to
    /// degraded (lexical-only) mode.
    public func installVectorizer(_ vectorizer: (any AmbientTextVectorizer)?) {
        box.withLock { state in state.vectorizer = vectorizer }
    }

    /// THE ONE WRITE FUNNEL. Replaces the scope's index wholesale — a scope's
    /// records are a fact about the last read, like the ledger's census.
    public func noteElements(
        _ records: [AmbientElementRecord],
        scope: AmbientElementScope,
        at now: Date = Date()
    ) {
        let (vectorizer, cached) = box.withLock { state in
            (state.vectorizer, state.vectorCache)
        }
        var fresh: [String: [Float]] = [:]
        if let vectorizer {
            for text in Set(records.flatMap(\.embedTexts))
            where cached[text] == nil && fresh[text] == nil {
                if let raw = vectorizer.vector(for: text) {
                    fresh[text] = AmbientVectorMath.normalized(raw)
                }
            }
        }
        let vectors = cached.merging(fresh) { first, _ in first }
        let index = AmbientElementIndex.build(records: records) { vectors[$0] }
        box.withLock { state in
            for (text, vector) in fresh where state.vectorCache[text] == nil {
                state.vectorCache[text] = vector
                state.cacheOrder.append(text)
            }
            while state.cacheOrder.count > Self.cacheCapacity {
                state.vectorCache[state.cacheOrder.removeFirst()] = nil
            }
            state.indexes[scope] = index
            state.notedAt[scope] = records.isEmpty ? nil : now
        }
    }

    public func index(for scope: AmbientElementScope) -> AmbientElementIndex? {
        box.withLock { state in state.indexes[scope] }
    }

    /// Scopes that published records recently enough to still describe the world.
    public func activeScopes(
        freshWithin horizon: TimeInterval, at now: Date = Date()
    ) -> [AmbientElementScope] {
        box.withLock { state in
            state.notedAt
                .filter { now.timeIntervalSince($0.value) <= horizon }
                .keys
                .filter { !(state.indexes[$0]?.entries.isEmpty ?? true) }
                .sorted { $0.key < $1.key }
        }
    }

    /// The query-side vectorization, memoized like the build side. Nil in
    /// degraded mode — callers fall back to lexical scoring.
    public func queryVector(for phrase: String) -> [Float]? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let (vectorizer, hit) = box.withLock { state in
            (state.vectorizer, state.vectorCache[trimmed])
        }
        if let hit { return hit }
        guard let raw = vectorizer?.vector(for: trimmed) else { return nil }
        let vector = AmbientVectorMath.normalized(raw)
        box.withLock { state in
            if state.vectorCache[trimmed] == nil {
                state.vectorCache[trimmed] = vector
                state.cacheOrder.append(trimmed)
                while state.cacheOrder.count > Self.cacheCapacity {
                    state.vectorCache[state.cacheOrder.removeFirst()] = nil
                }
            }
        }
        return vector
    }

    public func clear() {
        box.withLock { state in
            state.indexes = [:]
            state.vectorCache = [:]
            state.cacheOrder = []
        }
    }
}

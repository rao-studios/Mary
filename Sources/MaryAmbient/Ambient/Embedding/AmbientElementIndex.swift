//
//  AmbientElementIndex.swift
//  MaryAmbient
//
//  WHAT: One scope's elements, vectorized. Immutable; rebuilt at the write funnel.
//  IN:   AmbientElementRecord
//  OUT:  AmbientElementIndexStore / AmbientReferenceGate
//  PIN:  Same lifecycle as SemanticAbilityRequestIndex — wholesale swap under the store lock.
//
import Foundation

/// The prebuilt per-element vectors for one scope, plus the scoring path.
public struct AmbientElementIndex: Sendable {

    public struct Entry: Sendable {
        public var record: AmbientElementRecord
        /// L2-normalized, one per embed text that vectorized. May be empty
        /// (degraded mode) — the record still participates lexically.
        public var vectors: [[Float]]
    }

    public private(set) var entries: [Entry]

    public var records: [AmbientElementRecord] { entries.map(\.record) }

    /// `vectorize` runs OUTSIDE any lock — callers hand in a closure that
    /// consults their memoization cache first.
    public static func build(
        records: [AmbientElementRecord],
        vectorize: (String) -> [Float]?
    ) -> AmbientElementIndex {
        let entries = records.map { record in
            Entry(
                record: record,
                vectors: record.embedTexts.compactMap {
                    vectorize($0).map(AmbientVectorMath.normalized)
                })
        }
        return AmbientElementIndex(entries: entries)
    }

    /// Best dot product per element against a normalized query vector.
    /// Elements with no vectors are simply absent — lexical scoring is the
    /// gate's job, not this index's.
    public func semanticScores(forQueryVector query: [Float]) -> [String: Float] {
        var scores: [String: Float] = [:]
        for entry in entries {
            guard let best = entry.vectors
                .map({ AmbientVectorMath.dot($0, query) })
                .max()
            else { continue }
            let existing = scores[entry.record.elementID] ?? -1
            if best > existing { scores[entry.record.elementID] = best }
        }
        return scores
    }
}

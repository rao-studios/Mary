//
//  CachingVectorizer.swift
//  MaryBrainTests
//
//  WHAT: Memoize string -> vector across many index rebuilds.
//  IN:   hold-out grading, which rebuilds the corpora once per fixture.
//  PIN:  MEASUREMENT ONLY, and deliberately not `MaryEmbeddings.memo` —
//        that one is wiped every turn and keys on `RoutingQuery.firstLine`,
//        which silently truncates a multi-line corpus term. The measurement
//        suites bypass it on purpose, so a hold-out sweep needs its own.
//

import Foundation
import os
@testable import MaryAmbient
@testable import MaryBrain

/// Wraps any vectorizer and remembers what it has already been asked.
///
/// A leave-one-out sweep rebuilds every corpus once per fixture: ~159 builds
/// over ~1,500 terms is ~240,000 serialized `NLEmbedding` calls, which is
/// minutes. The union of terms across all those builds is only ~700, because
/// each build differs from the last by ONE sentence — so memoizing turns the
/// sweep into ~700 real calls and a great many dictionary hits.
final class CachingVectorizer: UtteranceVectorizer, @unchecked Sendable {

    private let underlying: any UtteranceVectorizer
    /// Nil is cached too: a term the model cannot vectorize is a stable fact,
    /// and re-asking on every rebuild is exactly the cost being avoided.
    private let cache = OSAllocatedUnfairLock<[String: [Float]?]>(initialState: [:])

    private(set) var misses = 0
    private(set) var hits = 0

    init(_ underlying: any UtteranceVectorizer) {
        self.underlying = underlying
    }

    func vector(for text: String) -> [Float]? {
        if let cached = cache.withLock({ $0[text] }) {
            hits += 1
            return cached
        }
        misses += 1
        let computed = underlying.vector(for: text)
        cache.withLock { $0[text] = computed }
        return computed
    }
}

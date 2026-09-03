//
//  RoutingHabitStoreTests.swift
//  MaryBrainTests
//
//  WHAT: The learning loop's store — what it vectorizes, what it keeps.
//  PIN:  These pin two defects that made the loop QUIETLY INERT rather than
//        wrong, which is why nothing caught them: a row stored in one shape
//        and scored in another, and a memo that outlived its rows.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct RoutingHabitStoreTests {

    /// THE INERTNESS FIX. Production recorded the COMPOSED routing query
    /// (utterance, then `lead:` and `recent:` lines) while every consumer
    /// scores `RoutingQuery.firstLine`. Vectorized whole, such a row barely
    /// resembles the utterance it came from — so the loop went dead exactly
    /// when a world snapshot existed, which is almost always.
    ///
    /// Read-time first-lining means rows already on disk regain their effect
    /// without a migration.
    @Test func aComposedRowScoresAsItsFirstLine() {
        let store = RoutingHabitStore()
        let composed = """
            the usual rao mix
            lead: Apple Music
            recent: what is playing | turn it up
            """
        store.record(RoutingHabit(
            query: composed,
            skillID: "multimedia.play-playlist",
            intent: AmbientIntent.operate.rawValue,
            ok: true))

        let vectorizer = LineVectorizer(lines: ["the usual rao mix"])
        let vectors = store.vectors(
            skillID: "multimedia.play-playlist", ok: true, vectorizer: vectorizer)

        #expect(vectors.count == 1, "the composed row must still vectorize")
        #expect(
            vectorizer.asked == ["the usual rao mix"],
            "it must be scored as its first line, not whole — asked: \(vectorizer.asked)")
    }

    /// A ROW EVICTED BY THE CAPS MUST NOT KEEP A WARM VECTOR. The memo was
    /// append-only and keyed by full query text, so it grew with every
    /// distinct sentence ever recorded, unbounded, for the life of the process.
    @Test func theMemoDoesNotOutliveItsRows() {
        let store = RoutingHabitStore()
        let vectorizer = LineVectorizer(lines: (0..<40).map { "phrase \($0)" })
        for index in 0..<40 {
            store.record(RoutingHabit(
                query: "phrase \(index)",
                skillID: "fixture.skill",
                intent: AmbientIntent.operate.rawValue,
                ok: true,
                storedAt: Date().addingTimeInterval(Double(index))))
            _ = store.vectors(skillID: "fixture.skill", ok: true, vectorizer: vectorizer)
        }
        // perSkillCap is 24, so 16 of the 40 have been evicted.
        #expect(store.count == RoutingHabitStore.perSkillCap)
        #expect(
            store.cachedVectorCountForTesting <= RoutingHabitStore.perSkillCap,
            "memo held \(store.cachedVectorCountForTesting) vectors for \(store.count) rows")
    }

    /// The derived view answers the two questions its readers ask, in recency
    /// order, without copying the whole store per call.
    @Test func queriesComeBackNewestFirstAndSplitByOutcome() {
        let store = RoutingHabitStore()
        let base = Date()
        store.record(RoutingHabit(
            query: "older", skillID: "s", intent: "operate", ok: true,
            storedAt: base.addingTimeInterval(-10)))
        store.record(RoutingHabit(
            query: "newer", skillID: "s", intent: "operate", ok: true, storedAt: base))
        store.record(RoutingHabit(
            query: "failed", skillID: "s", intent: "operate", ok: false, storedAt: base))

        #expect(store.queries(skillID: "s", ok: true) == ["newer", "older"])
        #expect(store.queries(skillID: "s", ok: false) == ["failed"])
        #expect(store.queries(intent: "operate", ok: true) == ["newer", "older"])
        #expect(store.queries(skillID: "absent", ok: true).isEmpty)
    }

    /// One basis vector per known line; anything else is nil. Records what it
    /// was ASKED to embed, which is the actual claim under test.
    private final class LineVectorizer: AmbientTextVectorizer, @unchecked Sendable {
        let lines: [String]
        private(set) var asked: [String] = []

        init(lines: [String]) { self.lines = lines }

        func vector(for text: String) -> [Float]? {
            asked.append(text)
            guard let index = lines.firstIndex(of: text) else { return nil }
            var vector = [Float](repeating: 0, count: lines.count)
            vector[index] = 1
            return vector
        }
    }
}

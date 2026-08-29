//
//  SemanticSkillAffinityCachingTests.swift
//  MaryBrainTests
//
//  THE PROOF FOR THE LATENCY FIX. `abilityRoutingContext()` used to call
//  `SemanticSkillRequestIndex.affinities(in:)` — one `NLEmbedding` sentence
//  vectorization plus a dot-product scan over the whole Skill library — on
//  every single invocation, and it is invoked from `schemas` (once per round
//  of the up-to-10-round local turn loop) AND from `dispatchCore` (once per
//  tool call). The same never-changes-within-a-turn utterance was being
//  re-embedded up to ~20 times per turn, serialized behind
//  `NLAmbientTextVectorizer`'s single process-wide lock.
//
//  THIS PINS THE CACHE'S CALL-COUNT CONTRACT rather than trusting that the
//  fix "should" be faster: exactly one `vector(for:)` call per turn no matter
//  how many times `schemas`/`abilityRosterTrace`/`dispatch` are read within
//  it, and a fresh call on the very next turn once a new utterance is noted —
//  proving the cache is turn-scoped, not just "compute once and never again".
//

import Foundation
import Testing
import os
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct SemanticSkillAffinityCachingTests {

    @Test func oneEmbeddingCallServesEveryRoundOfOneTurn() async throws {
        let vectorizer = CountingVectorizer(keywords: [("search", [1, 0, 0])])
        let snapshot = try buildSnapshot(vectorizer: vectorizer)
        // Building the index vectorizes every corpus term (title, summary,
        // invocation name, id) — real cost, but off the turn path in
        // production and irrelevant to what this test measures.
        vectorizer.reset()

        let ambient = AmbientContextStore()
        let runtime = AbilityRuntime(
            plugins: [],
            executionLog: AbilityExecutionLog(),
            ambient: ambient,
            passages: PassageRegistry()) {
                AbilityExecutionContext(projects: [:])
            }

        try await AbilityTurnContext.$snapshot.withValue(snapshot) {
            // THE PRODUCTION ORDER: `beginTurn()` runs before the new
            // utterance is noted (`MaryBrain+TurnLoop.swift`), and the cache
            // is a lazy compute-on-first-access — mirroring that order is
            // what makes this test honest about the real call sequence.
            runtime.beginTurn()
            ambient.noteUtterance("search the corpus for foo")

            // SIMULATING A MULTI-ROUND LOCAL TURN: `schemas` is read once per
            // round (up to `maxSkillRounds`), `abilityRosterTrace` is a
            // debugger read of the same routing verdict, and `dispatch`
            // rebuilds it again at tool-call time.
            _ = runtime.schemas
            _ = runtime.schemas
            _ = runtime.schemas
            _ = runtime.abilityRosterTrace
            _ = await runtime.dispatch(
                name: "semantic_cache_test_skill", argumentsJSON: "{}")

            #expect(vectorizer.count() == 1, """
                Five separate reads that each rebuild `abilityRoutingContext()` \
                (three `schemas`, one `abilityRosterTrace`, one `dispatch`) must \
                cost exactly one embedding call for the turn, not five.
                """)
        }
    }

    @Test func aNewTurnWithANewUtteranceRecomputes() async throws {
        let vectorizer = CountingVectorizer(keywords: [
            ("search", [1, 0, 0]),
            ("build", [0, 1, 0]),
        ])
        let snapshot = try buildSnapshot(vectorizer: vectorizer)
        vectorizer.reset()

        let ambient = AmbientContextStore()
        let runtime = AbilityRuntime(
            plugins: [],
            executionLog: AbilityExecutionLog(),
            ambient: ambient,
            passages: PassageRegistry()) {
                AbilityExecutionContext(projects: [:])
            }

        try await AbilityTurnContext.$snapshot.withValue(snapshot) {
            runtime.beginTurn()
            ambient.noteUtterance("search the corpus for foo")
            _ = runtime.schemas
            _ = runtime.schemas
            #expect(vectorizer.count() == 1, "first turn: one embedding for two rounds")

            // A NEW TURN, a genuinely different utterance — the cache must
            // not keep serving the first turn's stale affinities.
            runtime.beginTurn()
            ambient.noteUtterance("build the project now")
            _ = runtime.schemas
            _ = runtime.schemas
            _ = runtime.schemas
            #expect(vectorizer.count() == 2, """
                a new turn's `beginTurn()` must clear the memo, so the new \
                utterance is embedded exactly once more — not zero (stale) and \
                not three (uncached).
                """)
        }
    }

    // MARK: - Support

    private func buildSnapshot(
        vectorizer: CountingVectorizer
    ) throws -> AbilityRuntimeSnapshot {
        let skill = SkillSchema(
            id: "tests.semantic-cache.search",
            title: "Search The Corpus",
            summary: "Search project files for matching passages.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: "semantic_cache_test_skill"))
        let package = MaryAbilityPackage(
            package: .init(
                id: "tests.semantic-cache",
                version: "1.0.0",
                publisher: "tests",
                summary: "Semantic affinity caching fixture."),
            ability: .init(
                id: AbilityID("tests.semantic-cache"),
                title: "Semantic Cache Fixture",
                summary: "Semantic affinity caching fixture.",
                tint: "#123456",
                skills: [skill.id]),
            skills: [skill])
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/semantic-cache-fixture.mary"),
            validation: .init(),
            rawData: Data())

        let index = try #require(SemanticSkillRequestIndex.build(
            records: [record], vectorizer: vectorizer),
            "the fixture's own title must land at least one entry in the corpus")

        return AbilityRuntimeSnapshot(
            records: [record],
            validation: .init(),
            adapterManifests: [],
            semanticSkillIndex: index)
    }

    /// The brain-side twin of `CannedVectorizer`/`FakeVectorizer`, with a
    /// thread-safe call counter added — the one thing those two stubs don't
    /// need for their own purposes, and the one thing this suite exists to
    /// measure. First keyword contained in the text wins; unknown text
    /// vectorizes to nothing, exactly like a word the real model has no
    /// asset for.
    private struct CountingVectorizer: UtteranceVectorizer {
        let keywords: [(keyword: String, vector: [Float])]
        private let calls = OSAllocatedUnfairLock<Int>(initialState: 0)

        init(keywords: [(String, [Float])]) { self.keywords = keywords }

        func vector(for text: String) -> [Float]? {
            calls.withLock { $0 += 1 }
            let lowered = text.lowercased()
            return keywords.first { lowered.contains($0.keyword) }?.vector
        }

        func count() -> Int { calls.withLock { $0 } }
        func reset() { calls.withLock { $0 = 0 } }
    }
}

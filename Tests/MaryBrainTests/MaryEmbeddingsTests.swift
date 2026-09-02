//
//  MaryEmbeddingsTests.swift
//  MaryBrainTests
//
//  WHAT: The one place an engine is chosen, and the memo that lets an async
//        engine sit behind a synchronous protocol.
//  PIN:  A MISS IS NIL, NEVER A GUESS. Every scorer in Mary fail-closes on a
//        nil vector; that contract is the only reason a network engine can
//        serve `AmbientTextVectorizer` at all without blocking a turn.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain

@Suite struct MaryEmbeddingsTests {

    /// ENGINE IDENTITY TRAVELS. Two engines share no vector space, and
    /// `AmbientVectorMath.dot` answers a dimension mismatch with −1 — a silent
    /// "nothing matches" rather than an error. Anything cached or indexed has
    /// to be able to say what made it.
    @Test func everyEngineIsIdentifiable() {
        #expect(MaryEmbeddings.Engine.appleNL.id == "apple-nl")
        #expect(MaryEmbeddings.Engine.seer(model: "mistral-embed").id == "seer:mistral-embed")
        #expect(MaryEmbeddings.Engine.appleNL.id
            != MaryEmbeddings.Engine.seer(model: "mistral-embed").id)
    }

    /// Only the on-device engine can answer a synchronous read inline; the
    /// network tier can fill the memo ahead of time and nothing else.
    @Test func onlyTheLocalEngineIsSynchronous() {
        #expect(MaryEmbeddings.Engine.appleNL.isSynchronous)
        #expect(!MaryEmbeddings.Engine.seer(model: "m").isSynchronous)
    }

    /// A WARMED VECTOR SATISFIES A SYNC READ; an unwarmed one under a network
    /// engine abstains rather than blocking or inventing.
    @Test func theMemoServesTheSynchronousReader() async {
        let backend = ScriptedBackend(vector: [0.5, 0.5])
        MaryEmbeddings.installSeerBackend(backend, model: "test-embed")
        defer { MaryEmbeddings.endTurn() }

        // No local asset in CI, so the seer tier is the engine here.
        guard case .seer = MaryEmbeddings.engine() else { return }
        let vectorizer = try? #require(MaryEmbeddings.vectorizer())

        #expect(vectorizer?.vector(for: "cold text") == nil,
                "an unwarmed text under a network engine must abstain")

        await MaryEmbeddings.warm("warm text")
        #expect(vectorizer?.vector(for: "warm text") == [0.5, 0.5])
    }

    /// THE FIRST LINE IS THE KEY, because that is what every consumer scores —
    /// so warming the bare utterance also warms the composed routing query
    /// built from it, which is the whole reason one warm covers the turn.
    @Test func warmingTheUtteranceCoversTheComposedQuery() async {
        let backend = ScriptedBackend(vector: [1, 0])
        MaryEmbeddings.installSeerBackend(backend, model: "test-embed")
        defer { MaryEmbeddings.endTurn() }
        guard case .seer = MaryEmbeddings.engine() else { return }

        await MaryEmbeddings.warm("play my running mix")
        let composed = """
            play my running mix
            lead: Apple Music
            recent: what is playing
            """

        #expect(MaryEmbeddings.vectorizer()?.vector(for: composed) == [1, 0])
    }

    /// The memo is per turn — a lesson from one turn must not answer the next.
    @Test func endTurnDropsTheMemo() async {
        let backend = ScriptedBackend(vector: [1, 0])
        MaryEmbeddings.installSeerBackend(backend, model: "test-embed")
        guard case .seer = MaryEmbeddings.engine() else { return }

        await MaryEmbeddings.warm("this turn only")
        #expect(MaryEmbeddings.vectorizer()?.vector(for: "this turn only") != nil)

        MaryEmbeddings.endTurn()
        #expect(MaryEmbeddings.vectorizer()?.vector(for: "this turn only") == nil)
    }

    /// AN UNREACHABLE BACKEND WARMS NOTHING and raises nothing — the turn goes
    /// on without a vector, exactly as a machine with no engine does.
    @Test func afailingBackendLeavesTheMemoEmpty() async {
        MaryEmbeddings.installSeerBackend(FailingBackend(), model: "test-embed")
        defer { MaryEmbeddings.endTurn() }
        guard case .seer = MaryEmbeddings.engine() else { return }

        await MaryEmbeddings.warm("unreachable")

        #expect(MaryEmbeddings.vectorizer()?.vector(for: "unreachable") == nil)
    }

    // MARK: - Fixture

    private struct ScriptedBackend: SeerEmbeddingProviding {
        let vector: [Float]
        func isReady() async -> Bool { true }
        func embed(_ texts: [String]) async throws -> EmbeddedBatch {
            EmbeddedBatch(vectors: texts.map { _ in vector }, model: "test-embed")
        }
    }

    private struct FailingBackend: SeerEmbeddingProviding {
        func isReady() async -> Bool { false }
        func embed(_: [String]) async throws -> EmbeddedBatch {
            throw SeerEmbeddingError.unreachable("no stack")
        }
    }
}

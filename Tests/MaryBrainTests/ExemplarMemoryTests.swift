//
//  ExemplarMemoryTests.swift
//  MaryBrainTests
//
//  WHAT: The learning loop as PERSONAL MEMORY — taught once, recalled by
//        resemblance, scored in the corpus's own space.
//  PIN:  Durability left this process. What is pinned here is the CONTRACT the
//        backend must honour, so a Totem outage, a cold start and a fresh
//        install are all the same well-defined thing: route on the authored
//        corpus alone.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain

@Suite struct ExemplarMemoryTests {

    /// A LESSON GOES TO MEMORY, not to a file. The store keeps it for the rest
    /// of this turn as well, so a turn that dispatches twice sees the first
    /// lesson on its second read.
    @Test func recordingTeachesTheBackend() async {
        let memory = RecordingMemory()
        let store = RoutingExemplarStore(memory: memory)

        store.record(RoutingExemplar(
            query: "the usual rao mix",
            skillID: "multimedia.play-playlist",
            intent: AmbientIntent.operate.rawValue,
            ok: true))

        #expect(store.queries(skillID: "multimedia.play-playlist", ok: true)
            == ["the usual rao mix"], "usable at once, within the turn")
        await memory.settle()
        #expect(await memory.remembered.map(\.query) == ["the usual rao mix"])
    }

    /// A RECALL IS THE TURN'S WHOLE VIEW. Whatever memory returns is what the
    /// synchronous readers see — no accumulation across turns, because the
    /// lessons live in memory, not here.
    @Test func recallReplacesTheTurnsView() async {
        let memory = RecordingMemory(recalled: [
            RoutingExemplar(
                query: "put the running mix on", skillID: "multimedia.play-playlist",
                intent: AmbientIntent.operate.rawValue, ok: true),
        ])
        let store = RoutingExemplarStore(memory: memory)

        await store.recall(near: "play my running mix")
        #expect(store.queries(skillID: "multimedia.play-playlist", ok: true)
            == ["put the running mix on"])
        #expect(store.queries(intent: AmbientIntent.operate.rawValue, ok: true)
            == ["put the running mix on"])

        store.clearRecall()
        #expect(store.queries(skillID: "multimedia.play-playlist", ok: true).isEmpty)
    }

    /// THE HORIZON SURVIVES THE MOVE. Totem has no expiry of its own, so a
    /// lesson older than the horizon must be dropped on the way in — the
    /// store's own PIN is that a bad night must not pin a centroid, and a
    /// backend that remembers forever would make that permanent.
    @Test func recallDropsLessonsPastTheHorizon() async {
        let stale = Date().addingTimeInterval(-(RoutingExemplarStore.horizon + 60))
        let memory = RecordingMemory(recalled: [
            RoutingExemplar(
                query: "ancient phrasing", skillID: "s",
                intent: AmbientIntent.operate.rawValue, ok: true, storedAt: stale),
            RoutingExemplar(
                query: "recent phrasing", skillID: "s",
                intent: AmbientIntent.operate.rawValue, ok: true),
        ])
        let store = RoutingExemplarStore(memory: memory)

        await store.recall(near: "some phrasing")
        #expect(store.queries(skillID: "s", ok: true) == ["recent phrasing"])
    }

    /// AN UNREACHABLE BACKEND IS NOT AN ERROR. Totem down, mid-restart, or
    /// slower than the turn budget: the turn routes on its authored corpus,
    /// exactly as a fresh install does.
    @Test func anEmptyMemoryLeavesTheTurnOnItsCorpus() async {
        let store = RoutingExemplarStore(memory: EmptyRoutingExemplarMemory())

        await store.recall(near: "play my running mix")

        #expect(store.count == 0)
        #expect(store.queries(intent: AmbientIntent.operate.rawValue, ok: true).isEmpty)
    }

    /// RECALLED TEXT IS RE-SCORED LOCALLY. The backend ranked these in its own
    /// embedding space; the floor they are compared against belongs to the
    /// authored corpus's space. This pins that the store hands the caller's
    /// vectorizer the recalled TEXT rather than trusting a foreign score.
    @Test func recalledTextIsVectorizedByTheCallersVectorizer() async {
        let memory = RecordingMemory(recalled: [
            RoutingExemplar(
                query: "put the running mix on", skillID: "s",
                intent: AmbientIntent.operate.rawValue, ok: true),
        ])
        let store = RoutingExemplarStore(memory: memory)
        await store.recall(near: "play my running mix")

        let vectorizer = AskedVectorizer()
        let vectors = store.vectors(skillID: "s", ok: true, vectorizer: vectorizer)

        #expect(vectors.count == 1)
        #expect(vectorizer.asked == ["put the running mix on"])
    }

    // MARK: - Fixture

    private actor RecordingMemory: RoutingExemplarMemory {
        private(set) var remembered: [RoutingExemplar] = []
        private let recalled: [RoutingExemplar]

        init(recalled: [RoutingExemplar] = []) { self.recalled = recalled }

        func remember(_ exemplar: RoutingExemplar) async { remembered.append(exemplar) }
        func recall(near _: String, limit _: Int) async -> [RoutingExemplar] { recalled }

        /// `record` teaches without waiting, so a test must.
        func settle() async {
            for _ in 0..<200 where remembered.isEmpty {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    private final class AskedVectorizer: AmbientTextVectorizer, @unchecked Sendable {
        private(set) var asked: [String] = []
        func vector(for text: String) -> [Float]? {
            asked.append(text)
            return [1, 0]
        }
    }
}

//
//  EmbeddingCalibrationTests.swift
//  MaryBrainTests
//
//  WHAT: The real target query, through the REAL NLEmbedding asset — not the
//        orthogonal-cluster fake `EmbeddingRoutingTests` uses. Opt-in: run
//        with `MARY_EMBEDDING_CALIBRATION=1 swift test` on a Mac that has
//        the on-device English embedding asset. Skipped everywhere else,
//        including ordinary `swift test` and CI.
//  OUT:  SemanticIntentIndex + SemanticSkillRequestIndex, built from the
//        shipped `Abilities/` packages exactly as production builds them.
//  PIN:  This suite measures; it does not guess. If the with-world variant
//        ever fails here, the fix is to decide from THIS measurement —
//        classifying the query's first line, widening the corpus, or
//        raising/lowering a threshold — not to assume one in advance.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct EmbeddingCalibrationTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MARY_EMBEDDING_CALIBRATION"] == "1"
    }

    private static let screenshotOpen =
        "Can you open Apple Music and play the RAO playlist"
    private static let screenshotInApp =
        "Can you play the RAO playlist in Apple Music"

    private struct Environment {
        var snapshot: AbilityRuntimeSnapshot
        var intent: SemanticIntentIndex
        var skills: SemanticSkillRequestIndex
    }

    /// Every shipped package, exactly as `AbilityLibrary+PackageLifecycle`
    /// builds the production snapshot — no fixture, no fake vectorizer.
    private static func environment() throws -> Environment? {
        guard enabled else { return nil }
        guard let vectorizer = NLUtteranceVectorizer.shared else { return nil }
        guard let abilities = InstalledPackages.installed() else { return nil }
        let records = try FileManager.default
            .contentsOfDirectory(at: abilities, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mary" }
            .map { url -> AbilityPackageRecord in
                AbilityPackageRecord(
                    package: try AbilityPackageCodec.load(from: url),
                    source: .sourceTree, sourceURL: url,
                    validation: .init(), rawData: Data())
            }
        guard let intent = SemanticIntentIndex.build(records: records, vectorizer: vectorizer),
              let skillIndex = SemanticSkillRequestIndex.build(
                records: records, vectorizer: vectorizer)
        else { return nil }
        let abilityIndex = SemanticAbilityRequestIndex.build(
            records: records, vectorizer: vectorizer)
        let snapshot = AbilityRuntimeSnapshot(
            records: records,
            validation: .init(),
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters(),
                observers: MaryAdapterCatalog.observers()),
            semanticIndex: abilityIndex,
            semanticSkillIndex: skillIndex,
            semanticIntentIndex: intent)
        return Environment(snapshot: snapshot, intent: intent, skills: skillIndex)
    }

    private static func assertUniquePlayPlaylist(
        _ query: String, store: RoutingExemplarStore
    ) throws {
        guard let env = try environment() else { return }
        let verdict = try #require(
            env.intent.classify(query, exemplars: store),
            "did not classify at all: \"\(query)\"")
        #expect(verdict.intent == .operate, "\"\(query)\" classified \(verdict.intent), not operate")
        let winner = try #require(
            EmbeddingRouting.uniqueWinner(
                affinities: env.skills.affinities(in: query, exemplars: store),
                snapshot: env.snapshot),
            "\"\(query)\" had no unique Skill winner")
        #expect(
            winner.skill.id == SkillID("multimedia.play-playlist"),
            "\"\(query)\" uniquely picked \(winner.skill.id.rawValue), not multimedia.play-playlist")
    }

    /// Bare utterance — no world, no history. The floor case.
    @Test func bareUtterancesUniquelyPickPlayPlaylist() throws {
        let store = RoutingExemplarStore(persist: false)
        try Self.assertUniquePlayPlaylist(Self.screenshotOpen, store: store)
        try Self.assertUniquePlayPlaylist(Self.screenshotInApp, store: store)
    }

    /// The composed multi-line query — utterance plus snapshot plus recent
    /// turns, exactly as `RoutingQuery.compose` builds it in production. A
    /// real NLEmbedding sees the whole string, unlike the fake cluster
    /// vectorizer (which only ever looks at the first line) — this is the
    /// one measurement `EmbeddingRoutingTests` cannot make.
    @Test func composedSnapshotAndHistoryQueriesStillUniquelyPickPlayPlaylist() throws {
        let store = RoutingExemplarStore(persist: false)
        for utterance in [Self.screenshotOpen, Self.screenshotInApp] {
            let query = RoutingQuery.compose(
                utterance: utterance,
                world: AmbientWorld.Snapshot(
                    tier: .activation,
                    attention: .applications,
                    applicationID: "com.apple.dt.Xcode"),
                recentUserTurns: ["what's the time", "how's the weather"])
            try Self.assertUniquePlayPlaylist(query, store: store)
        }
    }
}

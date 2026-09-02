//
//  TurnTriageTests.swift
//  MaryBrainTests
//
//  WHAT: The one semantic read — abstention, the fail-closed contract, and
//        what the offered roster is allowed to win.
//  PIN:  CI-safe. A fake orthogonal vectorizer stands in for NLEmbedding, so
//        these assert the SEAM's behaviour, never the OS model's judgement.
//        Threshold movement is measured by EmbeddingCalibrationTests instead.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct TurnTriageTests {

    // MARK: - Abstention

    /// NO INDEX, NO OPINION — and `isActionShaped == false` here means "I
    /// cannot say", not "this is not an action". The distinction is the whole
    /// reason `intent` is optional: `AmbientEngine.classify` branches on nil
    /// to keep its lexical rungs reachable.
    @Test func anEmptyRegistryAbstainsRatherThanGuessing() {
        let verdict = TurnTriage.verdict(
            query: "play the evening playlist",
            registry: .empty,
            offeredNames: ["play_playlist"])

        #expect(verdict == TurnTriage.Verdict.abstained)
        #expect(verdict.intent == nil)
        #expect(!verdict.isActionShaped)
        #expect(verdict.uniqueSkill == nil)
        #expect(verdict.intentDescription == "intent=lexical")
    }

    // MARK: - The fail-closed contract

    /// AN INDEX THAT RECOGNIZES NOTHING STILL ANSWERS. A query no cluster
    /// matches must come back `.converse`, never nil — nil is reserved for
    /// "there is no index", and the engine reads the two differently.
    @Test func anUnrecognizedQueryFailsClosedToConverse() throws {
        guard let environment = try Self.environment() else { return }

        let verdict = TurnTriage.verdict(
            query: "xyzzy plugh nothing matches this",
            registry: environment,
            offeredNames: ["operate_thing"])

        #expect(verdict.intent == .converse, "an existing index must not answer nil")
        #expect(!verdict.isActionShaped)
        #expect(verdict.uniqueSkill == nil)
    }

    /// An operate verdict is action-shaped; a converse verdict is not.
    @Test func actionShapeFollowsTheIntent() throws {
        guard let environment = try Self.environment() else { return }

        let operate = TurnTriage.verdict(
            query: "operate the thing",
            registry: environment,
            offeredNames: ["operate_thing"])
        #expect(operate.intent == .operate)
        #expect(operate.isActionShaped)

        let converse = TurnTriage.verdict(
            query: "hello there",
            registry: environment,
            offeredNames: ["operate_thing"])
        #expect(converse.intent == .converse)
        #expect(!converse.isActionShaped)
    }

    // MARK: - The offered roster bounds the shortcut

    /// A SKILL THE ROSTER WITHHELD MAY NOT WIN. Affinity is not permission:
    /// the arbiter decides what is offered this turn, and a shortcut that
    /// ignored it would dispatch something the model was never shown.
    @Test func aSkillTheRosterWithheldCannotWin() throws {
        guard let environment = try Self.environment() else { return }

        let offered = TurnTriage.verdict(
            query: "operate the thing",
            registry: environment,
            offeredNames: ["operate_thing"])
        #expect(offered.uniqueSkill != nil, "offered, above the floor, so it wins")

        let withheld = TurnTriage.verdict(
            query: "operate the thing",
            registry: environment,
            offeredNames: [])
        #expect(withheld.uniqueSkill == nil)
        #expect(withheld.skillAffinities.isEmpty, "an unoffered skill is not even scored")
        #expect(withheld.intent == .operate, "but the intent still reads")
    }

    // MARK: - What gets embedded

    /// THE FIRST LINE ONLY. `RoutingQuery.compose` appends world and history
    /// lines, and a real sentence embedding dilutes badly once they are there
    /// — a query that wins bare can drop below the floor composed. Every
    /// consumer scores line one, and this pins that it still does.
    @Test func onlyTheFirstLineOfAComposedQueryIsScored() throws {
        guard let environment = try Self.environment() else { return }

        let bare = TurnTriage.verdict(
            query: "operate the thing",
            registry: environment,
            offeredNames: ["operate_thing"])
        let composed = TurnTriage.verdict(
            query: """
                operate the thing
                lead: some other place
                recent: hello there | what is the weather
                """,
            registry: environment,
            offeredNames: ["operate_thing"])

        #expect(composed.intent == bare.intent)
        #expect(composed.uniqueSkill?.id == bare.uniqueSkill?.id)
    }

    // MARK: - Fixture

    /// Two orthogonal clusters and a synthetic package that seeds one intent
    /// and one Skill. Anything unlisted vectorizes to nil, so a miss is a
    /// miss rather than a stale neighbour.
    private static func environment() throws -> AbilityRuntimeSnapshot? {
        let skill = SkillSchema(
            id: SkillID("fixture.operate-thing"),
            title: "Operate Thing",
            summary: "Fixture skill.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: "operate_thing"))
        let package = MaryAbilityPackage(
            package: .init(
                id: "tests.triage-fixture",
                version: "1.0.0",
                publisher: "tests",
                summary: "Triage fixture."),
            ability: .init(
                id: AbilityID("fixture-operate"),
                title: "Fixture",
                summary: "Fixture ability.",
                tint: "#112233",
                triggers: AbilityTriggerSchema(
                    tokens: ["operate the thing"],
                    intentExemplars: ["operate": ["operate the thing"]]),
                skills: [skill.id]),
            skills: [skill])
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/triage-fixture.mary"),
            validation: .init(),
            rawData: Data())
        let records = [record]
        let vectorizer = ClusterVectorizer(clusters: [
            ["operate the thing"],
            // The built-in converse baseline, so an unmatched query has
            // somewhere to fail closed to.
            ["hello", "how are you", "thanks", "good morning",
             "tell me a joke", "what do you think about that"],
        ])
        guard let intent = SemanticIntentIndex.build(
                records: records, vectorizer: vectorizer),
              let skills = SemanticSkillRequestIndex.build(
                records: records, vectorizer: vectorizer)
        else { return nil }
        return AbilityRuntimeSnapshot(
            records: records,
            validation: .init(),
            adapterManifests: [],
            semanticIndex: SemanticAbilityRequestIndex.build(
                records: records, vectorizer: vectorizer),
            semanticSkillIndex: skills,
            semanticIntentIndex: intent)
    }

    private struct ClusterVectorizer: AmbientTextVectorizer {
        let members: [String: Int]
        let dimension: Int

        init(clusters: [[String]]) {
            dimension = max(clusters.count, 1)
            var map: [String: Int] = [:]
            for (index, cluster) in clusters.enumerated() {
                for text in cluster { map[Self.fold(text)] = index }
            }
            members = map
        }

        func vector(for text: String) -> [Float]? {
            let first = text.split(
                omittingEmptySubsequences: true, whereSeparator: \.isNewline
            ).first.map(String.init) ?? text
            if let index = members[Self.fold(first)] { return basis(index) }
            if let index = members[Self.fold(text)] { return basis(index) }
            return nil
        }

        private func basis(_ index: Int) -> [Float] {
            var vector = [Float](repeating: 0, count: dimension)
            guard index < dimension else { return vector }
            vector[index] = 1
            return vector
        }

        static func fold(_ text: String) -> String {
            text.lowercased()
                .split { $0.isNewline || $0.isWhitespace }
                .joined(separator: " ")
        }
    }
}

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
        let environment = try #require(try Self.environment(), "fixture failed to build")

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
        let environment = try #require(try Self.environment(), "fixture failed to build")

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
        let environment = try #require(try Self.environment(), "fixture failed to build")

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
        let environment = try #require(try Self.environment(), "fixture failed to build")

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

    // MARK: - Promotion by the skill corpus

    /// THE STUCK CASE. When the intent index has no opinion at all but exactly
    /// one OFFERED Skill clears the floor with a margin, the skill corpus is
    /// the only voice saying what the words are about — and believing the
    /// fail-closed "converse" instead is self-sealing: no dispatch, so no
    /// habit, so the phrasing is never learned. Ever.
    @Test func aUniqueSkillPromotesAFailClosedConverse() throws {
        let environment = try #require(try Self.environment(), "fixture failed to build")

        let verdict = TurnTriage.verdict(
            query: "wrangle the widget",
            registry: environment,
            offeredNames: ["operate_thing"],
            habits: RoutingHabitStore())

        #expect(verdict.uniqueSkill != nil)
        #expect(verdict.intent == .operate)
        #expect(verdict.isActionShaped)
        #expect(verdict.promotedByUniqueSkill)
        #expect(verdict.intentDescription == "intent=operate promoted=skill",
                "the log must not report a score the intent index never gave")
    }

    /// A SCORED CONVERSE IS A VERDICT and blocks the promotion. Only the
    /// ABSENCE of an opinion may be overridden by the skill corpus.
    @Test func aScoredConverseIsNotPromoted() throws {
        let environment = try #require(try Self.environment(), "fixture failed to build")

        let verdict = TurnTriage.verdict(
            query: "hello there",
            registry: environment,
            offeredNames: ["operate_thing"],
            habits: RoutingHabitStore())

        #expect(verdict.intent == .converse)
        #expect(!verdict.promotedByUniqueSkill)
        #expect(!verdict.isActionShaped)
    }

    /// NO WINNER, NO PROMOTION — a fail-closed converse with nothing unique
    /// behind it stays converse.
    @Test func aFailClosedConverseWithoutAWinnerStaysConverse() throws {
        let environment = try #require(try Self.environment(), "fixture failed to build")

        let verdict = TurnTriage.verdict(
            query: "xyzzy plugh nothing matches this",
            registry: environment,
            offeredNames: ["operate_thing"],
            habits: RoutingHabitStore())

        #expect(verdict.uniqueSkill == nil)
        #expect(verdict.intent == .converse)
        #expect(!verdict.promotedByUniqueSkill)
    }

    /// AND THE ROSTER STILL BOUNDS IT. A Skill the arbiter withheld cannot
    /// promote a turn, because it was never a candidate to win.
    @Test func aWithheldSkillCannotPromote() throws {
        let environment = try #require(try Self.environment(), "fixture failed to build")

        let verdict = TurnTriage.verdict(
            query: "wrangle the widget",
            registry: environment,
            offeredNames: [],
            habits: RoutingHabitStore())

        #expect(verdict.uniqueSkill == nil)
        #expect(!verdict.promotedByUniqueSkill)
        #expect(verdict.intent == .converse)
    }

    // MARK: - Fixture

    /// Two orthogonal clusters and a synthetic package that seeds one intent
    /// and one Skill. Anything unlisted vectorizes to nil, so a miss is a
    /// miss rather than a stale neighbour.
    /// FAILS LOUDLY when it cannot build. This used to return nil on a corpus
    /// that would not vectorize, and every `guard let ... else { return }`
    /// above turned that into a silent pass.
    private static func environment() throws -> AbilityRuntime.Snapshot? {
        let skill = SkillSchema(
            id: SkillID("fixture.operate-thing"),
            title: "Operate Thing",
            summary: "Fixture skill.",
            kind: .cognitive,
            execution: .init(
                kind: .binding,
                bindings: [.init(adapterID: AdapterID("fixture"), operation: "operate_thing")]),
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
                    intentSeeds: ["operate": ["operate the thing"]]),
                skills: [skill.id]),
            skills: [skill],
            // A whole sentence the SKILL corpus knows and no intent seed
            // shares — the shape of the stuck case.
            fixtures: [AbilityFixture(
                id: "skill-only",
                utterance: "wrangle the widget",
                expectedSkill: skill.id,
                expectedDisposition: "route")])
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/triage-fixture.mary"),
            validation: .init(),
            rawData: Data())
        let records = [record]
        let vectorizer = ClusterVectorizer(clusters: [
            // The query, AND the Skill's own corpus terms — the index skips a
            // Skill whose every term fails to vectorize, which silently made
            // this whole fixture nil.
            ["operate the thing", "Operate Thing", "operate thing",
             "fixture operate thing", "Fixture skill."],
            // Skill corpus only — no intent seed shares this basis.
            ["wrangle the widget"],
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
        // `EmbeddingRouting.uniqueWinner` takes only READY, model-exposed
        // Skills, so the fixture needs an adapter publishing its operation —
        // without it nothing could ever win and the roster tests were empty.
        let manifest = InstalledAdapterManifest(
            adapterID: AdapterID("fixture"),
            title: "Fixture",
            transport: .native,
            operations: [InstalledAdapterBinding(
                adapterID: AdapterID("fixture"), operation: "operate_thing")])
        return AbilityRuntime.Snapshot(
            records: records,
            validation: .init(),
            adapterManifests: [manifest],
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

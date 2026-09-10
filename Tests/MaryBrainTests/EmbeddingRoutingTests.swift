//
//  EmbeddingRoutingTests.swift
//  MaryBrainTests
//
//  WHAT: Fake orthogonal clusters — playlist vs song, look vs operate, habits.
//  OUT:  SemanticIntentIndex / SemanticSkillRequestIndex / EmbeddingRouting.uniqueWinner
//  PIN:  A miss is nil, never a leftover shared vector.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct EmbeddingRoutingTests {

    private static let screenshotOpen =
        "Can you open Apple Music and play the RAO playlist"
    private static let screenshotInApp =
        "Can you play the RAO playlist in Apple Music"

    /// Real aliases — the extractor's leading/trailing app-context peel keys
    /// off exactly this, never a hardcoded "apple music" list.
    private static let appleMusicProfile = ApplicationProfile(
        id: "apple-music",
        title: "Music",
        summary: "The macOS Music app.",
        aliases: ["apple music", "the music app", "itunes"])

    @Test func screenshotUtterancesOperateAndUniquePlayPlaylist() throws {
        let env = try #require(try Self.environment(), "fixture failed to build")
        let store = RoutingHabitStore()
        for utterance in [Self.screenshotOpen, Self.screenshotInApp] {
            let query = RoutingQuery.compose(
                utterance: utterance,
                world: AmbientWorld.Snapshot(
                    sense: .workspace,
                    attention: .applications,
                    applicationID: "com.apple.dt.Xcode"))
            let verdict = try #require(
                env.intent.classify(query, habits: store),
                "\(utterance) did not classify")
            #expect(verdict.intent == .operate, "\(utterance)")
            let affinities = env.skills.affinities(in: query, habits: store)
            let winner = try #require(
                EmbeddingRouting.uniqueWinner(
                    affinities: affinities, snapshot: env.snapshot),
                "\(utterance) had no unique Skill")
            #expect(winner.skill.id == SkillID("multimedia.play-playlist"), "\(utterance)")
            #expect(EmbeddingRouting.confidenceShape(of: winner) != nil, "\(utterance)")
            // The extracted argument must be the PLAYLIST SPAN, never the
            // whole sentence — this is the screenshot's own bug.
            let argumentsJSON = EmbeddingRouting.argumentsJSON(
                for: winner, utterance: utterance, applicationID: "apple-music",
                applicationProfiles: [Self.appleMusicProfile])
            #expect(argumentsJSON.contains("RAO"), "\(utterance) -> \(argumentsJSON)")
            #expect(!argumentsJSON.contains("Can you"), "\(utterance) -> \(argumentsJSON)")
            #expect(
                !argumentsJSON.localizedCaseInsensitiveContains("apple music"),
                "\(utterance) -> \(argumentsJSON)")
        }
    }

    @Test func aSongTitlePicksPlayMusicNotPlayPlaylist() throws {
        let env = try #require(try Self.environment(), "fixture failed to build")
        let store = RoutingHabitStore()
        let utterance = "Play Stand by Me."
        let verdict = try #require(env.intent.classify(utterance, habits: store))
        #expect(verdict.intent == .operate)
        let winner = try #require(
            EmbeddingRouting.uniqueWinner(
                affinities: env.skills.affinities(in: utterance, habits: store),
                snapshot: env.snapshot))
        #expect(winner.skill.id == SkillID("multimedia.play-music"))
    }

    @Test func lookingAtCodeWithACodingLeadIsPerceive() throws {
        let env = try #require(try Self.environment(), "fixture failed to build")
        let store = RoutingHabitStore()
        let query = RoutingQuery.compose(
            utterance: "Let's look at this code",
            world: AmbientWorld.Snapshot(
                sense: .workspace,
                attention: .applications,
                subject: "main.swift",
                applicationID: "com.apple.dt.Xcode"))
        let verdict = try #require(env.intent.classify(query, habits: store))
        #expect(verdict.intent == .perceive)
        #expect(
            EmbeddingRouting.uniqueWinner(
                affinities: env.skills.affinities(in: query, habits: store),
                snapshot: env.snapshot) == nil)
    }

    @Test func anOkHabitPullsAParaphraseAboveTheFloor() throws {
        let env = try #require(try Self.environment(), "fixture failed to build")
        let empty = RoutingHabitStore()
        let loaded = RoutingHabitStore()
        let paraphrase = "that rao mix again"
        #expect(env.skills.affinities(in: paraphrase, habits: empty).isEmpty)
        loaded.record(RoutingHabit(
            query: "the usual rao mix",
            skillID: "multimedia.play-playlist",
            intent: AmbientIntent.operate.rawValue,
            ok: true))
        let affinities = env.skills.affinities(in: paraphrase, habits: loaded)
        #expect(
            (affinities[SkillID("multimedia.play-playlist")] ?? 0)
                >= EmbeddingRouting.floor)
    }

    @Test func requestedAbilitiesAreSemanticOnlyWhenAnIndexExists() throws {
        let env = try #require(try Self.environment(), "fixture failed to build")
        let requested = env.snapshot.requestedAbilities(in: Self.screenshotInApp)
        #expect(requested.contains(AbilityID("multimedia")))
        #expect(
            !env.snapshot.requestedAbilities(in: "xyzzy-no-cluster").contains(
                AbilityID("multimedia")))
    }

    // MARK: - Argument-extraction eligibility

    /// A single required string parameter with `requiresComposition: true`
    /// (a commit message, replacement prose) must NOT be offered the
    /// confidence-dispatch shortcut, even though it is otherwise shaped
    /// exactly like an eligible skill — the naive "exactly one required
    /// string param" heuristic alone would wrongly admit it.
    @Test func aRequiresCompositionParameterIsNotEligible() throws {
        let skill = Self.fixtureSkill(
            skillID: "fixture.commit-changes",
            invocationName: "commit_changes",
            parameters: [
                .init(
                    name: "message", type: "string", summary: "Commit message.",
                    required: true, requiresComposition: true),
            ])
        #expect(EmbeddingRouting.confidenceShape(of: skill) == nil)
    }

    /// A single required string parameter carrying `enumValues` (a closed
    /// transport verb, not a spoken span) is excluded by the structural
    /// check alone — no `requiresComposition` needed.
    @Test func anEnumParameterIsNotEligible() throws {
        let skill = Self.fixtureSkill(
            skillID: "fixture.control-playback",
            invocationName: "control_playback",
            parameters: [
                .init(
                    name: "action", type: "string", summary: "What to do.",
                    required: true, enumValues: ["play", "pause", "skip"]),
            ])
        #expect(EmbeddingRouting.confidenceShape(of: skill) == nil)
    }

    /// A plain single required string parameter — the (b)-shape this whole
    /// mechanism exists for — stays eligible.
    @Test func aPlainRequiredStringParameterIsEligible() throws {
        let skill = Self.fixtureSkill(
            skillID: "fixture.find-playlist",
            invocationName: "find_playlist",
            parameters: [
                .init(name: "query", type: "string", summary: "Which playlist.", required: true),
            ])
        #expect(EmbeddingRouting.confidenceShape(of: skill) == .singleString)
    }

    /// AN OPTIONAL STRING THE PACKAGE SAYS THE SENTENCE FILLS. "Go back two
    /// minutes in the video" names the seek AND how far; the enum took "go
    /// back", and the span that remains is the time. An optional plain string
    /// was unfillable by construction, so every seek cost a model round.
    @Test func aSpokenSpanFillsAnOptionalString() throws {
        let skill = Self.fixtureSkill(
            skillID: "fixture.seek", invocationName: "control_media",
            parameters: [
                .init(
                    name: "action", type: "string", summary: "", required: true,
                    enumValues: ["seek", "pause"],
                    spokenValues: ["seek": ["go back", "skip ahead"]]),
                .init(
                    name: "position", type: "string", summary: "", required: false,
                    spokenSpan: true),
                .init(name: "note", type: "string", summary: "", required: false),
            ])
        let filled = EmbeddingRouting.filledArguments(
            for: skill, utterance: "Can you go back two minutes in the video", applicationID: nil)
        let arguments = try #require(
            try JSONSerialization.jsonObject(with: Data(filled.json.utf8)) as? [String: String])
        #expect(arguments["action"] == "seek")
        #expect(arguments["position"]?.contains("two minutes") == true)
        // An optional string NOT marked is left alone — a span nobody asked for.
        #expect(arguments["note"] == nil)
        #expect(filled.stages.contains { $0.hasPrefix("span position") })
    }

    private static func fixtureSkill(
        skillID: String, invocationName: String, parameters: [ModelParameterSchema]
    ) -> AbilityRuntimeSkill {
        let skill = SkillSchema(
            id: SkillID(skillID),
            title: "Fixture",
            summary: "Eligibility fixture.",
            kind: .effectful,
            execution: .init(kind: .binding),
            modelExposure: .init(invocationName: invocationName, parameters: parameters))
        let package = MaryAbilityPackage(
            package: .init(
                id: "tests.eligibility-fixture",
                version: "1.0.0",
                publisher: "tests",
                summary: "Eligibility fixture."),
            ability: .init(
                id: AbilityID("fixture-eligibility"),
                title: "Fixture",
                summary: "Fixture ability.",
                tint: "#112233",
                skills: [skill.id]),
            skills: [skill])
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/eligibility-fixture.mary"),
            validation: .init(),
            rawData: Data())
        let snapshot = AbilityRuntime.Snapshot(
            records: [record], validation: .init(), adapterManifests: [])
        return snapshot.skills.first { $0.skill.id == skill.id }!
    }

    // MARK: - Cluster vectorizer

    private struct ClusterVectorizer: AmbientTextVectorizer {
        let members: [String: Int]
        let dimension: Int

        init(clusters: [[String]]) {
            dimension = max(clusters.count, 1)
            var map: [String: Int] = [:]
            for (index, cluster) in clusters.enumerated() {
                for text in cluster {
                    map[Self.fold(text)] = index
                }
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

    private struct Environment {
        var snapshot: AbilityRuntime.Snapshot
        var intent: SemanticIntentIndex
        var skills: SemanticSkillRequestIndex
    }

    /// A minimal synthetic package carrying only the `perceive` habits —
    /// the real `coding.mary` seeds these, but this suite loads only
    /// `multimedia.mary` (the package the confidence-dispatch tests are
    /// about), so a small fixture record supplies the third cluster the
    /// intent index needs to classify against. `converse` needs no fixture:
    /// `SemanticIntentIndex.build` always seeds its own built-in baseline.
    private static func perceiveFixtureRecord() -> AbilityPackageRecord {
        let skill = SkillSchema(
            id: SkillID("fixture.look"),
            title: "Look",
            summary: "Fixture skill so the package has one.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: "fixture_look"))
        let package = MaryAbilityPackage(
            package: .init(
                id: "tests.perceive-fixture",
                version: "1.0.0",
                publisher: "tests",
                summary: "Perceive-intent seed fixture."),
            ability: .init(
                id: AbilityID("fixture-perceive"),
                title: "Fixture",
                summary: "Fixture ability.",
                tint: "#112233",
                triggers: AbilityTriggerSchema(intentSeeds: [
                    "perceive": [
                        "look at this code",
                        "let's take a look at this",
                        "what's on my screen",
                        "what am i looking at",
                        "do you see this",
                        "read this paragraph",
                    ],
                ]),
                skills: [skill.id]),
            skills: [skill])
        return AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/perceive-fixture.mary"),
            validation: .init(),
            rawData: Data())
    }

    private static func environment() throws -> Environment? {
        guard let abilities = InstalledPackages.installed() else { return nil }
        let url = abilities.appendingPathComponent("multimedia.mary")
        let package = try AbilityPackageCodec.load(from: url)
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: url,
            validation: .init(),
            rawData: Data())
        let records = [record, perceiveFixtureRecord()]
        let vectorizer = ClusterVectorizer(clusters: clusters)
        guard let intent = SemanticIntentIndex.build(
                records: records, vectorizer: vectorizer),
              let skillIndex = SemanticSkillRequestIndex.build(
                records: records, vectorizer: vectorizer)
        else { return nil }
        let abilityIndex = SemanticAbilityRequestIndex.build(
            records: records, vectorizer: vectorizer)
        let snapshot = AbilityRuntime.Snapshot(
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

    /// Orthogonal clusters. A string that is not listed returns nil.
    private static let clusters: [[String]] = [
        // 0 — playlist / operate seeds the screenshot shares
        [
            "play the playlist",
            "play my workout playlist",
            "open apple music and play a playlist",
            "can you play the playlist in apple music",
            "put on my running mix",
            "play playlist",
            "play my dinner office playlist.",
            "put on my running mix",
            screenshotOpen,
            screenshotInApp,
            "multimedia play playlist",
        ],
        // 1 — perceive
        [
            "look at this code",
            "let's take a look at this",
            "what's on my screen",
            "what am I looking at",
            "do you see this",
            "read this paragraph",
            "Let's look at this code",
            "let's look at this code",
        ],
        // 2 — song / play_music
        [
            "play this song",
            "play that track",
            "Play Stand by Me.",
            "play stand by me.",
            "play music",
            "multimedia play music",
        ],
        // 3 — pause / skip (operate, not a unique playlist winner)
        [
            "pause the music",
            "skip this song",
        ],
        // 4 — habit paraphrase pair (orthogonal to playlist seeds)
        [
            "the usual rao mix",
            "that rao mix again",
        ],
        // 5 — shuffle
        [
            "shuffle my playlist",
            "shuffle playlist",
            "Shuffle my Dinner Office playlist.",
            "Play my running mix on shuffle.",
        ],
        // 6 — converse
        [
            "hello",
            "how are you",
            "what do you think about that",
            "tell me a joke",
            "thanks",
            "good morning",
        ],
    ]
}

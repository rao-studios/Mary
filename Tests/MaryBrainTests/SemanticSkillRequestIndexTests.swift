//
//  SemanticSkillRequestIndexTests.swift
//  MaryBrainTests
//
//  DETERMINISTIC VECTORS ONLY. `NLEmbedding` output varies by OS build, so
//  nothing here touches the real model — the stub below is the brain-side twin
//  of `CannedVectorizer` in Tests/MaryAmbientTests/EmbeddingTestSupport.swift
//  and must be edited in lockstep with it (test targets cannot import test
//  targets, and PackageLayeringTests refuses a new one).
//
//  WHAT IS ACTUALLY WORTH PINNING here is not the arithmetic — it is the
//  CONTRACT: this index can only ever ADD. A Skill it has no opinion about has
//  to score exactly what it scored before the seam existed, and no similarity,
//  however high, may reach `isEligible`. Those two are the whole safety
//  argument for turning embeddings on below the Ability tier, and both are
//  properties a plausible-looking refactor could quietly delete.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct SemanticSkillRequestIndexTests {

    // MARK: - The additive contract

    /// ZERO AFFINITY IS ZERO BONUS, at the floor and below it. This is the
    /// line that makes "nothing changes for Skills the index is silent about"
    /// true rather than hoped for.
    @Test func anIndifferentSkillContributesNothing() {
        #expect(SemanticSkillRequestIndex.bonus(for: 0) == 0)
        #expect(SemanticSkillRequestIndex.bonus(for: 0.61) == 0)
        #expect(SemanticSkillRequestIndex.bonus(for: SemanticSkillRequestIndex.defaultThreshold) == 0)
        // A negative similarity is a real value out of a dot product, and it
        // must not become a negative bonus — subtracting evidence would be a
        // veto wearing a different hat.
        #expect(SemanticSkillRequestIndex.bonus(for: -0.4) == 0)
    }

    /// THE CAP, checked against the number it is supposed to sit under rather
    /// than against itself. `utterancePhrase` scores 50 in `predicateScore`; an
    /// author writing a phrase must always outrank a machine guessing one.
    @Test func theBonusStaysBelowAnAuthoredPhrase() {
        #expect(SemanticSkillRequestIndex.bonus(for: 1.0)
            == SemanticSkillRequestIndex.maximumBonus)
        #expect(SemanticSkillRequestIndex.maximumBonus < 50)
        // Monotonic in between, so a better match never scores worse.
        #expect(SemanticSkillRequestIndex.bonus(for: 0.8)
            > SemanticSkillRequestIndex.bonus(for: 0.7))
    }

    /// EVIDENCE, NEVER ADMISSION. The same context, the same policy, and an
    /// affinity of 1.0 — the strongest signal the index can produce — must not
    /// move `isEligible` by so much as a boolean.
    @Test func noAffinityCanMakeAnIneligibleSkillEligible() {
        let policy = RoutingPolicySchema(
            eligibility: RoutingPredicate(kind: .targetClass, value: "media-player"),
            preference: 100)
        let wrongPlaceEntirely = AbilityRoutingContext(
            utterance: "play my running mix",
            targetClasses: ["code-workspace"],
            semanticSkillAffinity: ["multimedia.play-playlist": 1.0])

        #expect(!AbilityRoutingEvaluator.isEligible(policy, in: wrongPlaceEntirely))
    }

    /// The other half of the same contract: where the Skill IS eligible, the
    /// affinity shows up in the score and nowhere else.
    @Test func anAffinityRaisesTheScoreOfAnAlreadyEligibleSkill() {
        let policy = RoutingPolicySchema(
            eligibility: RoutingPredicate(kind: .targetClass, value: "media-player"),
            preference: 100)
        let atThePlayer = AbilityRoutingContext(
            utterance: "put on my running mix",
            targetClasses: ["media-player"])
        let sameTurnWithRecall = AbilityRoutingContext(
            utterance: "put on my running mix",
            targetClasses: ["media-player"],
            semanticSkillAffinity: ["multimedia.play-playlist": 0.9])

        let without = AbilityRosterArbitrator.evidence(
            policy: policy, requirements: nil, context: atThePlayer,
            skillID: "multimedia.play-playlist")
        let with = AbilityRosterArbitrator.evidence(
            policy: policy, requirements: nil, context: sameTurnWithRecall,
            skillID: "multimedia.play-playlist")
        let unrelated = AbilityRosterArbitrator.evidence(
            policy: policy, requirements: nil, context: sameTurnWithRecall,
            skillID: "multimedia.now-playing")

        #expect(with.total > without.total)
        #expect(with.total - without.total == SemanticSkillRequestIndex.bonus(for: 0.9))
        // A Skill the index said nothing about is untouched even on a turn
        // where another Skill scored.
        #expect(unrelated.total == without.total)
    }

    /// A call site that passes no Skill id — the Ability-level one at
    /// `AbilityRosterArbitrator.swift:158` — must be unable to pick up another
    /// Skill's affinity by accident.
    @Test func anAnonymousScoreIgnoresEveryAffinity() {
        let policy = RoutingPolicySchema(preference: 100)
        let context = AbilityRoutingContext(
            utterance: "put on my running mix",
            semanticSkillAffinity: ["multimedia.play-playlist": 1.0])

        #expect(AbilityRosterArbitrator.evidence(
            policy: policy, requirements: nil, context: context).total == 0)
    }

    // MARK: - The corpus

    /// Ids are not language. If this stops being true the sentence model is
    /// being asked to embed "play_playlist", which it has no reading of.
    @Test func idsAreSpokenAsWords() {
        #expect(SemanticSkillRequestIndex.deslugged("play_playlist") == "play playlist")
        #expect(SemanticSkillRequestIndex.deslugged("multimedia.shuffle-playlist")
            == "multimedia shuffle playlist")
    }

    /// ONLY THE UTTERANCE ARMS. A target class or an interaction id is a
    /// machine fact; embedding "media-player" would teach the index that it is
    /// something a person says.
    @Test func onlyUtterancePredicatesJoinTheCorpus() {
        let tree = RoutingPredicate(kind: .any, children: [
            RoutingPredicate(kind: .targetClass, value: "media-player"),
            RoutingPredicate(kind: .utteranceToken, value: "playlist"),
            RoutingPredicate(kind: .all, children: [
                RoutingPredicate(kind: .hasInteraction, value: "interaction.text-selection"),
                RoutingPredicate(kind: .utterancePhrase, value: "put on my"),
            ]),
        ])

        #expect(SemanticSkillRequestIndex.utteranceValues(in: tree)
            == ["playlist", "put on my"])
    }

    /// THE FLOOR IS A FLOOR, and the corpus is the real one. Built over the
    /// shipped `multimedia.mary` rather than a hand-made fixture, because the
    /// thing worth proving is that the package's OWN text — titles, invocation
    /// names, the utterance arms authored in Step 2, and the route fixtures
    /// that name a Skill — is what lands in the index. A fixture package would
    /// prove the arithmetic and none of that.
    @Test func theRealPackageCorpusRecallsAndAbstains() throws {
        guard InstalledPackages.installed() != nil else { return }
        let vectorizer = FakeVectorizer(keywords: [
            ("playlist", [1, 0, 0]),
            ("shuffle", [1, 0, 0]),
            ("build", [0, 1, 0]),
        ])
        let index = try #require(
            SemanticSkillRequestIndex.build(
                records: [try multimediaRecord()], vectorizer: vectorizer))

        // A word the stub has never heard vectorizes to nothing, so the query
        // produces no affinities at all rather than a map of zeroes — the
        // consumer reads presence, not magnitude.
        #expect(index.affinities(in: "what is the weather").isEmpty)

        let recalled = index.affinities(in: "start a playlist")
        #expect(recalled["multimedia.play-playlist"] != nil,
                "the playlist Skills must be reachable from the package's own corpus")
        #expect(recalled["multimedia.find-playlist"] != nil)
    }

    // MARK: - Support

    /// The brain-side twin of `CannedVectorizer`. First keyword contained in
    /// the text wins; unknown text vectorizes to nothing, exactly like a word
    /// the real model has no asset for.
    private struct FakeVectorizer: UtteranceVectorizer {
        var keywords: [(keyword: String, vector: [Float])]

        init(keywords: [(String, [Float])]) { self.keywords = keywords }

        func vector(for text: String) -> [Float]? {
            let lowered = text.lowercased()
            return keywords.first { lowered.contains($0.keyword) }?.vector
        }
    }

    private func multimediaRecord() throws -> AbilityPackageRecord {
        guard let abilities = InstalledPackages.installed() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = abilities.appendingPathComponent("multimedia.mary")
        return AbilityPackageRecord(
            package: try AbilityPackageCodec.load(from: url),
            source: .sourceTree,
            sourceURL: url,
            validation: AbilityPackageValidation(issues: []),
            rawData: try Data(contentsOf: url))
    }
}

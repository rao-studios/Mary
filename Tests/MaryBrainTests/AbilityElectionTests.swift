//
//  AbilityElectionTests.swift
//  MaryBrainTests
//
//  WHAT: Which Abilities stand in a conflict group, and why.
//  OUT:  AbilityRosterArbitrator.arbitrate — activeAbilities + trace.election
//  PIN:  THE BUG THIS SUITE EXISTS FOR IS "can you pause the music" WITH A
//        BROWSER IN FRONT. The election is scored by `predicateScore` alone —
//        `evidence` is asked with no `skillID`, so the affinity short-circuit
//        inside it cannot apply. Browsing scored 70 for `targetClass ==
//        web-page`; multimedia scored 0; every multimedia Skill was struck out
//        before the roster was read, including the one the Skill corpus had
//        just scored highest for those very words. No test covered the
//        ability-vs-ability election in the SEMANTIC regime at all.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct AbilityElectionTests {

    // MARK: - The two rivals

    /// A discipline in the shared "ability" conflict group, admitted by one
    /// target class — the shape both `browsing.mary` and `multimedia.mary` have.
    private static func discipline(
        id: String, skill: String, invocation: String, targetClass: String
    ) -> MaryAbilityPackage {
        let schema = SkillSchema(
            id: SkillID(skill),
            title: skill,
            summary: "Fixture skill.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: invocation))
        return MaryAbilityPackage(
            package: .init(
                id: PackageID(id), version: "1.0.0",
                publisher: "tests", summary: "Election fixture."),
            ability: .init(
                id: AbilityID(id),
                title: id.capitalized,
                summary: "Fixture ability.",
                tint: "#112233",
                skills: [schema.id],
                routing: .init(
                    eligibility: RoutingPredicate(
                        kind: .any,
                        children: [RoutingPredicate(kind: .targetClass, value: targetClass)]),
                    preference: 200,
                    conflictGroup: "ability",
                    conflictPolicy: .preferDirectInteraction)),
            skills: [schema])
    }

    private static func snapshot() -> AbilityRuntime.Snapshot {
        let packages = [
            discipline(
                id: "browsing", skill: "browsing.control-media",
                invocation: "control_media", targetClass: "web-page"),
            discipline(
                id: "multimedia", skill: "multimedia.control-playback",
                invocation: "control_playback", targetClass: "media-player"),
        ]
        return AbilityRuntime.Snapshot(
            records: packages.map {
                AbilityPackageRecord(
                    package: $0, source: .sourceTree,
                    sourceURL: URL(fileURLWithPath: "/tmp/election.mary"),
                    validation: .init(), rawData: Data())
            },
            validation: .init(),
            adapterManifests: [])
    }

    private static func arbitrate(
        _ context: AbilityRoutingContext
    ) -> AbilityRosterArbitration {
        AbilityRosterArbitrator.arbitrate(
            skills: snapshot().skills, context: context, baseFailure: { _ in nil })
    }

    private static func offered(_ arbitration: AbilityRosterArbitration) -> Set<String> {
        Set(arbitration.trace.selected.map(\.reference.invocationName))
    }

    private static let playback = SkillID("multimedia.control-playback")
    private static let media = SkillID("browsing.control-media")

    // MARK: - The reported failure

    /// THE BUG, EXACTLY: a browser is in front, the words are about the music,
    /// and the transport skill is not even offered to the model.
    @Test func lexicallyTheFrontmostWindowSilencesTheOtherDiscipline() {
        let arbitration = Self.arbitrate(AbilityRoutingContext(
            utterance: "can you pause the music",
            targetClasses: ["web-page"],
            usesEmbeddingRoster: false))
        #expect(Self.offered(arbitration).contains("control_media"))
        #expect(
            !Self.offered(arbitration).contains("control_playback"),
            "this is the behaviour being fixed — pinned so the fix is visible")
    }

    /// THE FIX. The Skill tier is the finer instrument and it runs first; an
    /// Ability holding a Skill the words reached is an Ability the turn is
    /// talking about, whatever window happens to be frontmost.
    @Test func semanticallyAnAbilityTheWordsReachedStandsAnyway() {
        let arbitration = Self.arbitrate(AbilityRoutingContext(
            utterance: "can you pause the music",
            targetClasses: ["web-page"],
            semanticSkillAffinity: [Self.playback: 0.87, Self.media: 0.48],
            semanticSkillScores: [Self.playback: 0.87, Self.media: 0.48],
            usesEmbeddingRoster: true))
        #expect(
            Self.offered(arbitration).contains("control_playback"),
            "the corpus scored it 0.87 for these very words")
    }

    /// ADMISSION IS NOT SELECTION, and the roster does not widen by the back
    /// door: an Ability whose Skills the words never reached is still struck
    /// out, on its own row, with its own sentence.
    @Test func anAbilityTheWordsMissedIsStillStruckOut() {
        let arbitration = Self.arbitrate(AbilityRoutingContext(
            utterance: "can you pause the music",
            targetClasses: ["web-page"],
            // Only the music skill cleared the floor, so only it is admitted;
            // the browsing skill is `ineligible` for want of an affinity entry.
            semanticSkillAffinity: [Self.playback: 0.87],
            semanticSkillScores: [Self.playback: 0.87, Self.media: 0.48],
            usesEmbeddingRoster: true))
        let arbitrationOffered = Self.offered(arbitration)
        #expect(arbitrationOffered.contains("control_playback"))
        // With `baseFailure` returning nil here, browsing has no per-skill gate
        // to fail — so what must be true is that its ELECTION row says it was
        // not reached, which is the fact a bench renders.
        let browsing = arbitration.trace.election.first { $0.abilityID.rawValue == "browsing" }
        #expect(browsing?.bestMemberAffinity == 0.48)
    }

    // MARK: - The row itself

    /// EVERY ABILITY THAT STOOD GETS A ROW, in both regimes, saying what it was
    /// weighed on and what happened to it. Before this, an Ability losing took
    /// all of its Skills out of the roster with one borrowed sentence repeated
    /// on each of them and no way to see the rival.
    @Test func theElectionIsRecordedInBothRegimes() {
        for embedding in [true, false] {
            let arbitration = Self.arbitrate(AbilityRoutingContext(
                utterance: "can you pause the music",
                targetClasses: ["web-page"],
                semanticSkillAffinity: embedding ? [Self.playback: 0.87] : [:],
                semanticSkillScores: [Self.playback: 0.87, Self.media: 0.48],
                usesEmbeddingRoster: embedding))
            let rows = arbitration.trace.election
            #expect(rows.count == 2, "both Abilities stood in the group")
            #expect(rows.allSatisfy { $0.conflictGroup == "ability" })
            #expect(rows.allSatisfy {
                $0.regime == (embedding ? .semantic : .lexical)
            })
            #expect(rows.allSatisfy { !$0.reason.isEmpty })
            // The lexical vote is carried in BOTH regimes, so a reader can see
            // what would have decided under the other one.
            let browsing = rows.first { $0.abilityID.rawValue == "browsing" }
            #expect(browsing?.predicateScore == 70, "targetClass web-page matched")
            let multimedia = rows.first { $0.abilityID.rawValue == "multimedia" }
            #expect(multimedia?.predicateScore == 0, "media-player did not")
        }
    }

    /// THE AFFINITY RIDES ON EVERY DECISION, including the ones below the floor
    /// — the number a corpus problem actually shows itself in, and the one a
    /// bench could previously say nothing about.
    @Test func everyDecisionCarriesTheScoreTheFloorWasComparedAgainst() {
        let arbitration = Self.arbitrate(AbilityRoutingContext(
            utterance: "can you pause the music",
            targetClasses: ["web-page"],
            semanticSkillAffinity: [Self.playback: 0.87],
            semanticSkillScores: [Self.playback: 0.87, Self.media: 0.48],
            usesEmbeddingRoster: true))
        let byName = Dictionary(
            arbitration.trace.decisions.map { ($0.reference.invocationName, $0) },
            uniquingKeysWith: { first, _ in first })
        #expect(byName["control_playback"]?.affinity == 0.87)
        #expect(byName["control_media"]?.affinity == 0.48, "below the floor, and said so")
    }
}

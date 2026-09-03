//
//  ConfidenceDispatchTests.swift
//  MaryBrainTests
//
//  WHAT: When a turn may act with no model round at all.
//  OUT:  EmbeddingRouting.confidenceShape / isSingleClause
//  PIN:  REPLACES DeterministicWindowVerbTests. Window verbs used to reach
//        this path through a hand-written gate that named two Skills; they
//        now arrive as ordinary Skills that happen to need no argument. The
//        gate's real claims — a compound request keeps its lane, a Skill
//        needing a title cannot be guessed at blindly — are kept here as
//        properties of the shape rule rather than of a list of verb names.
//
import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct ConfidenceDispatchTests {

    // MARK: - Which shapes may skip the model

    /// THE CASE THE OLD RULE EXCLUDED BY ACCIDENT. A Skill needing no
    /// argument is the safest shortcut there is — there is no span to
    /// mis-extract — yet it was ineligible because the rule was written when
    /// every shortcut carried a title.
    @Test func aSkillNeedingNoArgumentQualifies() {
        #expect(
            EmbeddingRouting.confidenceShape(of: Self.skill(required: []))
                == .noRequiredArguments)
    }

    /// One plain spoken span still qualifies.
    @Test func aSingleRequiredStringQualifies() {
        #expect(
            EmbeddingRouting.confidenceShape(
                of: Self.skill(required: [("window", "string", [], false)]))
                == .singleString)
    }

    /// STRUCTURED DATA IS NOT A SPOKEN SPAN, and composed content is not a
    /// span at all — both keep their model round.
    @Test func enumsAndComposedContentDoNotQualify() {
        #expect(
            EmbeddingRouting.confidenceShape(
                of: Self.skill(required: [("mode", "string", ["a", "b"], false)])) == nil)
        #expect(
            EmbeddingRouting.confidenceShape(
                of: Self.skill(required: [("text", "string", [], true)])) == nil)
        #expect(
            EmbeddingRouting.confidenceShape(
                of: Self.skill(required: [("count", "number", [], false)])) == nil)
    }

    /// Two required arguments is a form, not an utterance.
    @Test func twoRequiredArgumentsDoNotQualify() {
        #expect(
            EmbeddingRouting.confidenceShape(of: Self.skill(required: [
                ("window", "string", [], false), ("app", "string", [], false),
            ])) == nil)
    }

    // MARK: - What a zero-argument verb may claim

    /// A verb carrying no span claims the WHOLE sentence, so it only acts on a
    /// whole simple one. THIS IS THE DELETED GATE'S REAL CLAIM: dispatching
    /// the first half of a compound request silently drops the second.
    @Test(arguments: [
        "bring all my windows forward and close the last one",
        "list my windows then bring them forward",
        "bring them forward, also hide the rest",
        "bring my windows forward plus tidy the desktop",
        "what windows do I have open?",
        "could you please go through and bring every single one of my open windows forward now",
    ])
    func acompoundOrQuestioningSentenceKeepsItsLane(_ utterance: String) {
        #expect(!EmbeddingRouting.isSingleClause(utterance), "[\(utterance)]")
    }

    @Test(arguments: [
        "bring all my windows forward",
        "list my open windows",
        "make this full screen",
        "exit full screen",
    ])
    func aWholeSimpleSentenceMayAct(_ utterance: String) {
        #expect(EmbeddingRouting.isSingleClause(utterance), "[\(utterance)]")
    }

    /// FUNCTION-WORD SHAPE, NOT VOCABULARY. The rule reads joiners and
    /// punctuation; it never asks what the sentence is about, so it stays
    /// true for a Skill in any domain.
    @Test func theClauseRuleNamesNoDomain() {
        #expect(EmbeddingRouting.isSingleClause("play the evening playlist"))
        #expect(!EmbeddingRouting.isSingleClause("play the playlist and turn it up"))
    }

    // MARK: - Fixture

    private static func skill(
        required: [(String, String, [String], Bool)]
    ) -> AbilityRuntimeSkill {
        let parameters = required.map { name, type, enumValues, composed in
            ModelParameterSchema(
                name: name,
                type: type,
                summary: "Fixture parameter.",
                required: true,
                enumValues: enumValues,
                requiresComposition: composed)
        }
        let schema = SkillSchema(
            id: SkillID("fixture.shape"),
            title: "Shape",
            summary: "Fixture skill.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(
                invocationName: "fixture_shape", parameters: parameters))
        let package = MaryAbilityPackage(
            package: .init(
                id: PackageID("tests.shape"),
                version: "1.0.0",
                publisher: "tests",
                summary: "Shape fixture."),
            ability: .init(
                id: AbilityID("fixture-shape"),
                title: "Fixture",
                summary: "Fixture ability.",
                tint: "#112233",
                skills: [schema.id]),
            skills: [schema])
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/shape.mary"),
            validation: .init(),
            rawData: Data())
        let snapshot = AbilityRuntime.Snapshot(
            records: [record], validation: .init(), adapterManifests: [])
        return snapshot.skills.first { $0.skill.id == schema.id }!
    }
}

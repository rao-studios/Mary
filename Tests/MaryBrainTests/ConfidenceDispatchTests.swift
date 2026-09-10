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

    /// COMPOSED CONTENT IS NOT A SPAN AT ALL, and a number is not spoken —
    /// both keep their model round whatever the sentence says.
    @Test func composedContentAndNonStringsDoNotQualify() {
        #expect(
            EmbeddingRouting.confidenceShape(
                of: Self.skill(required: [("text", "string", [], true)]),
                utterance: "write it up") == nil)
        #expect(
            EmbeddingRouting.confidenceShape(
                of: Self.skill(required: [("count", "number", [], false)]),
                utterance: "three of them") == nil)
    }

    /// AN ENUM VALUE THE PERSON ACTUALLY NAMED IS A THING THEY SAID.
    ///
    /// THE BUG THIS FIXES: enums were excluded wholesale as "structured data,
    /// not a spoken span" — true of the span, wrong about the value. "pause" IS
    /// the enum member, said out loud. The exclusion is what made every "can you
    /// pause the music" cost a model round, and a small model with two
    /// near-identical transport skills in front of it is exactly where that
    /// round goes wrong. The gate is now the sentence, not the type.
    @Test func anEnumValueTheSentenceNamesQualifies() {
        let skill = Self.skill(required: [("mode", "string", ["pause", "play"], false)])
        #expect(
            EmbeddingRouting.confidenceShape(of: skill, utterance: "pause it")
                == .singleEnum)
    }

    /// AND NOTHING ELSE DOES. No value named, or two named, still goes to the
    /// model — including the shape-only ask, which has no sentence to read.
    @Test func anEnumWithoutOneNamedValueDoesNot() {
        let skill = Self.skill(required: [("mode", "string", ["pause", "play"], false)])
        #expect(EmbeddingRouting.confidenceShape(of: skill) == nil)
        #expect(EmbeddingRouting.confidenceShape(of: skill, utterance: "do it") == nil)
        #expect(
            EmbeddingRouting.confidenceShape(of: skill, utterance: "pause it then play it")
                == nil)
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
        "could you please go through and bring every single one of my open windows forward now",
        // A "?" in the MIDDLE really is two utterances run together.
        "is that up? bring them forward",
    ])
    func acompoundSentenceKeepsItsLane(_ utterance: String) {
        #expect(!EmbeddingRouting.isSingleClause(utterance), "[\(utterance)]")
    }

    /// A TRAILING QUESTION MARK ENDS A SENTENCE; IT DOES NOT JOIN TWO.
    ///
    /// Dictation punctuates. "Can you go back?" is one clause and one act, and
    /// refusing it for its final character sent a plain request to the model
    /// while the identical sentence without the mark acted immediately.
    @Test(arguments: [
        "can you go back?",
        "bring all my windows forward?",
        "exit full screen?",
    ])
    func aDictatedQuestionMarkIsStillOneClause(_ utterance: String) {
        #expect(EmbeddingRouting.isSingleClause(utterance), "[\(utterance)]")
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

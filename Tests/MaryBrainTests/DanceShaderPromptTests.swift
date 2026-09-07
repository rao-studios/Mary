//
//  DanceShaderPromptTests.swift
//  MaryBrainTests
//
//  WHAT: A composer's reply is read for its feeling and its shader.
//  OUT:  DanceShaderPrompt.parse / prompt
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin

@Suite struct DanceShaderPromptTests {

    static let shader = "precision highp float;\nvoid main() { gl_FragColor = vec4(1.0); }"

    @Test func theShapeItAskedForReads() throws {
        let reply = "FEELING: Restless, mostly.\n```glsl\n\(Self.shader)\n```"
        let composition = try #require(DanceShaderPrompt.parse(reply))
        #expect(composition.feeling == "Restless, mostly.")
        #expect(composition.glsl == reply)
        #expect(GLSLFragment.admit(composition.glsl).map(\.source) == .success(Self.shader))
    }

    @Test func aBoldOrPrefacedFeelingStillReads() throws {
        let reply = "Sure.\n**FEELING:** *Quiet, and a little tired.*\n\n```\n\(Self.shader)\n```"
        let composition = try #require(DanceShaderPrompt.parse(reply))
        #expect(composition.feeling == "Quiet, and a little tired.")
    }

    @Test func aMissingFeelingLineFallsBackToProse() throws {
        let reply = "Here is something calm.\n```glsl\n\(Self.shader)\n```"
        let composition = try #require(DanceShaderPrompt.parse(reply))
        #expect(composition.feeling == "Here is something calm.")
        let bare = try #require(DanceShaderPrompt.parse("```glsl\n\(Self.shader)\n```"))
        #expect(bare.feeling == "Here.")
    }

    /// Line 17 in the compiler's log is line 17 here — fences stripped, numbered from one.
    @Test func theRepairShaderIsNumberedLikeTheCompilerCounts() {
        let fenced = "FEELING: x\n```glsl\n\(Self.shader)\n```"
        let lines = DanceShaderPrompt.numbered(fenced)
        #expect(lines == ["1: precision highp float;", "2: void main() { gl_FragColor = vec4(1.0); }"])
        #expect(DanceShaderPrompt.numbered("float a;") == ["1: float a;"])
    }

    @Test func aReplyWithNoShaderIsNil() {
        #expect(DanceShaderPrompt.parse("") == nil)
        #expect(DanceShaderPrompt.parse("I'd rather not.") == nil)
        #expect(DanceShaderPrompt.parse("FEELING: fine.") == nil)
    }

    @Test func aLongFeelingIsCut() throws {
        let long = String(repeating: "very ", count: 60) + "long."
        let composition = try #require(DanceShaderPrompt.parse("FEELING: \(long)\n```\n\(Self.shader)\n```"))
        #expect(composition.feeling.count <= DanceShaderPrompt.maximumFeelingLength + 1)
        #expect(composition.feeling.hasSuffix("…"))
    }

    @Test func thePromptCarriesTheBrief() {
        let brief = DanceBrief(
            subject: .person, utterance: "What do you think I feel like right now?",
            moodHint: "tired", motifs: ["amber", "drift", "grain"],
            repair: .init(glsl: "float a;", problem: "The shader has no main()."))
        let prompt = DanceShaderPrompt.prompt(
            for: brief, recentLines: ["they: long day", "Mary: I noticed."],
            now: Date(timeIntervalSince1970: 0))
        #expect(prompt.contains("what you think they feel like"))
        #expect(prompt.contains("\"What do you think I feel like right now?\""))
        #expect(prompt.contains("A hint about the mood: tired"))
        #expect(prompt.contains("amber, drift, grain"))
        #expect(prompt.contains("they: long day"))
        #expect(prompt.contains("was refused: The shader has no main()."))
        #expect(prompt.contains("1: float a;"), "the previous shader is numbered the way the compiler counts")
        let variant = DanceShaderPrompt.prompt(
            for: DanceBrief(subject: .dance, utterance: "Let's dance.", motifs: ["teal"], variant: (3, 5)))
        #expect(variant.contains("shader 3 of 5"))
        #expect(variant.contains("unlike the others"))
        #expect(DanceShaderPrompt.systemPrompt.contains("gl_FragColor"))
        #expect(DanceShaderPrompt.systemPrompt.contains("no textures"))
    }
}

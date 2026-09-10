//
//  SpokenReadBackTests.swift
//  MaryBrainTests
//
//  WHAT: Two pure functions the turn leans on — the deterministic read-back,
//        and the recognizer the synthetic-nudge prune matches by shape.
//  OUT:  MaryBrain+GroundedText.spokenReadBack; MaryPrompts.isAffordanceNudge
//  PIN:  NEITHER IS ENGINE-SEAT-ONLY, which is why they moved out of the suite
//        they were written in (EngineTurnRungTests, which drives `engineTurn`).
//        `spokenReadBack` is read by the SEWN follow-up too
//        (MaryBrain+FollowUpSpeech), and `isAffordanceNudge` by
//        `pruneSyntheticTurns`. No brain, no harness — these are functions.
//

import Foundation
import Testing
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct SpokenReadBackTests {

    /// The recognizer the prune depends on actually recognizes the nudge it is given —
    /// and nothing else. A prune that matched loosely would eat the person's own words.
    @Test func theAffordanceNudgeIsRecognizable() {
        let nudge = MaryPrompts.affordanceNudge(labels: ["Accept all", "Reject"])
        #expect(MaryPrompts.isAffordanceNudge(nudge))
        #expect(!MaryPrompts.isAffordanceNudge("press accept all"))
        #expect(!MaryPrompts.isAffordanceNudge(MaryPrompts.continuationNudge))
    }

    /// THE PASSAGE ITSELF, as the deterministic voice takes it: header dropped,
    /// clamped to two breaths, and empty when there is nothing readable to say.
    @Test func theReadBackTakesThePassageAndNotItsHeader() {
        let read = MaryBrain.LaneOutcome(
            skillName: "read_page_text",
            outcome: SkillOutcome(ok: true, summary: Self.passage))
        let line = MaryBrain.spokenReadBack(outcomes: [read])
        #expect(line.hasPrefix("Ski touring"))
        #expect(!line.contains("The visible part"))
        #expect(line.count <= MaryBrain.readBackClamp + 1)

        // A MISS IS NOT A PASSAGE, and neither is a failure.
        let miss = MaryBrain.LaneOutcome(
            skillName: "read_page_text",
            outcome: SkillOutcome(
                ok: true, summary: "I can read nothing on this page.",
                foundNothing: true))
        #expect(MaryBrain.spokenReadBack(outcomes: [miss]).isEmpty)
    }

    private static let passage = """
        The visible part of Ski touring, top to bottom:
        Ski touring
        Ski touring is skiing in the backcountry on unmarked slopes.
        """
}

//
//  SpokenFailureHintTests.swift
//  MaryBrainTests
//
//  WHAT: A binding's spoken failure hint decorates failures, never questions.
//  OUT:  AbilityRuntime.hinted
//  PIN:  THE BUG THIS PINS SENT SOMEBODY TO THE WRONG SETTING. `act_on_screen`
//        dispatched with no `goal` answers "What would you like me to do on
//        screen?" — a request for the argument it was never given — and the
//        hint turned that into "… — check Accessibility in my Settings", which
//        reads as a permission failure and is nothing of the kind. Measured on
//        the Sand bench, where the roster had offered nothing else.
//

import Testing
@testable import MaryBrain
@testable import MaryPlugin

@Suite struct SpokenFailureHintTests {

    private static func binding(
        hint: String? = "check Accessibility in my Settings"
    ) -> SkillBinding {
        SkillBinding(
            name: "act_on_screen",
            description: "Fixture binding.",
            access: .tweak,
            backing: .native { _, _ in SkillOutcome(ok: true, summary: "ok") },
            spokenFailureHint: hint)
    }

    /// A QUESTION ASKS FOR INPUT. Nothing failed, so nothing is explained.
    @Test(arguments: [
        "What would you like me to do on screen?",
        "Tell me how loud — halfway, or a quarter?",
        "What would you like me to do on screen?   ",
    ])
    func aQuestionIsLeftAlone(_ summary: String) {
        let outcome = AbilityRuntime.hinted(
            SkillOutcome(ok: false, summary: summary), Self.binding())
        #expect(outcome.summary == summary, "[\(summary)]")
    }

    /// AND A REAL FAILURE STILL SAYS WHERE TO LOOK.
    @Test func aFailureIsStillHinted() {
        let outcome = AbilityRuntime.hinted(
            SkillOutcome(ok: false, summary: "I couldn't press that."),
            Self.binding())
        #expect(outcome.summary
            == "I couldn't press that. — check Accessibility in my Settings")
    }

    /// Said once, however many times it passes through.
    @Test func theHintIsNeverDoubled() {
        let once = AbilityRuntime.hinted(
            SkillOutcome(ok: false, summary: "I couldn't press that."),
            Self.binding())
        let twice = AbilityRuntime.hinted(once, Self.binding())
        #expect(twice.summary == once.summary)
    }

    /// A SUCCESS IS NEVER DECORATED, and a binding with no hint has nothing to add.
    @Test func successAndHintlessBindingsAreUntouched() {
        let succeeded = AbilityRuntime.hinted(
            SkillOutcome(ok: true, summary: "Pressed it."), Self.binding())
        #expect(succeeded.summary == "Pressed it.")
        let hintless = AbilityRuntime.hinted(
            SkillOutcome(ok: false, summary: "I couldn't press that."),
            Self.binding(hint: nil))
        #expect(hintless.summary == "I couldn't press that.")
    }
}

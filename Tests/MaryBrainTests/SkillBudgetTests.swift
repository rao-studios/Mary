//
//  SkillBudgetTests.swift
//  MaryBrainTests
//
//  WHAT: The dispatch deadline — a floor real acts can land inside, never the
//        slider's raw value.
//  OUT:  AbilityRuntime.effectiveBudget
//  PIN:  Pure statics, no runtime — the whole point is that this arithmetic
//        is checkable without dispatching anything.
//

import Testing
@testable import MaryBrain

@Suite struct SkillBudgetTests {

    /// THE REPORTED BUG, PINNED DIRECTLY. `play_playlist` is an ordinary
    /// binding with no table entry; at the slider's default it used to be
    /// killed at 2 s while Apple Music was still mid-press. It must now get
    /// the floor.
    @Test func anOrdinaryDispatchNeverFallsBelowTheLandingFloor() {
        let budget = AbilityRuntime.effectiveBudget(
            bindingName: "play_playlist",
            userCap: AbilityRuntime.ordinarySkillTimeoutDefault)
        #expect(budget == AbilityRuntime.ordinaryLandingFloor)
    }

    /// The slider is not inert — asking for longer than the floor is honoured.
    @Test func theSliderCanExtendPastTheFloor() {
        let budget = AbilityRuntime.effectiveBudget(
            bindingName: "play_playlist",
            userCap: AbilityRuntime.ordinarySkillTimeoutMaximum)
        #expect(budget == AbilityRuntime.ordinarySkillTimeoutMaximum)
    }

    /// A slider value BELOW the floor never wins — it would only recreate
    /// the reported bug at a different number.
    @Test func aSliderValueBelowTheFloorIsIgnored() {
        let budget = AbilityRuntime.effectiveBudget(
            bindingName: "play_playlist", userCap: 1)
        #expect(budget == AbilityRuntime.ordinaryLandingFloor)
    }

    /// Named long jobs keep their own table ceiling regardless of the floor
    /// or the slider — they were never the bug, and must not move.
    @Test func namedLongJobsKeepTheirOwnCeilingRegardlessOfTheFloor() {
        let atDefault = AbilityRuntime.effectiveBudget(
            bindingName: "run_tests", userCap: AbilityRuntime.ordinarySkillTimeoutDefault)
        let atMaximum = AbilityRuntime.effectiveBudget(
            bindingName: "run_tests", userCap: AbilityRuntime.ordinarySkillTimeoutMaximum)
        #expect(atDefault == 330)
        #expect(atMaximum == 330)
    }

    /// A capability's own duration constraint still outranks the floor — the
    /// floor guarantees a MINIMUM wait, never forces a maximum past a real
    /// safety constraint a package declared.
    @Test func capabilityPolicyStillTightensBelowTheFloor() {
        let budget = AbilityRuntime.effectiveBudget(
            bindingName: "play_playlist",
            userCap: AbilityRuntime.ordinarySkillTimeoutDefault,
            maximumDurationSeconds: 5)
        #expect(budget == 5)
    }

    /// A WORKFLOW'S OWN DECLARED CEILING WINS OUTRIGHT — a package stating
    /// its work takes up to ten minutes must not be crushed by the slider,
    /// the way `coding.pair-program` (timeoutSeconds: 600) was before this
    /// fix: at the slider default it used to land at 2 seconds.
    @Test func aWorkflowsDeclaredTimeoutOutranksTheSliderAndTheFloor() {
        let budget = AbilityRuntime.effectiveBudget(
            bindingName: "pair_program",
            userCap: AbilityRuntime.ordinarySkillTimeoutDefault,
            declaredTimeoutSeconds: 600)
        #expect(budget == 600)
    }

    /// ...but a capability policy cap still bounds even a declared workflow
    /// ceiling — packages may shorten Mary's ceiling, never enlarge it.
    @Test func aPolicyCapStillBoundsADeclaredWorkflowTimeout() {
        let budget = AbilityRuntime.effectiveBudget(
            bindingName: "pair_program",
            userCap: AbilityRuntime.ordinarySkillTimeoutDefault,
            declaredTimeoutSeconds: 600,
            maximumDurationSeconds: 120)
        #expect(budget == 120)
    }

    /// The exact regression this whole phase exists to close: the old
    /// two-second default must never again reach a real act's deadline.
    @Test func theOldTwoSecondDefaultNoLongerReachesEffectiveBudget() {
        for name in ["play_playlist", "shuffle_playlist", "find_playlist", "pair_program"] {
            let budget = AbilityRuntime.effectiveBudget(bindingName: name, userCap: 2)
            #expect(budget >= AbilityRuntime.ordinaryLandingFloor, "\(name) got \(budget)s")
        }
    }

    /// The commented-out special cases are gone — the floor covers them
    /// without a named entry, so the table stays short.
    @Test func theTableNamesOnlyGenuinelyLongJobs() {
        #expect(AbilityRuntime.skillBudgets["play_playlist"] == nil)
        #expect(AbilityRuntime.skillBudgets["shuffle_playlist"] == nil)
        #expect(AbilityRuntime.skillBudgets["find_playlist"] == nil)
    }

    /// The slider's own bounds match what the plan asked for: default 2,
    /// ceiling 30.
    @Test func theSliderRangeIsTwoToThirty() {
        #expect(AbilityRuntime.ordinarySkillTimeoutDefault == 2)
        #expect(AbilityRuntime.ordinarySkillTimeoutMaximum == 30)
        #expect(AbilityRuntime.clampedOrdinarySkillTimeout(999) == 30)
        #expect(AbilityRuntime.clampedOrdinarySkillTimeout(0) == 1)
    }
}

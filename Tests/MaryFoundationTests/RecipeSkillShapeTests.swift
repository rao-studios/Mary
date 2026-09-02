//
//  RecipeSkillShapeTests.swift
//  MaryFoundationTests
//
//  WHAT: The Skill shape Ability Studio's "add a recipe" writes must validate.
//  IN:   AbilityPackageValidator.
//  OUT:  Ability Studio (AbilityStudioAuthoringDocument.addRecipeSkill).
//  PIN:  The Studio lives in MaryApp, which has no test target. This pins the
//        SHAPE it produces, so a validator rule that moves under it fails here
//        rather than in someone's editor.
//

import Foundation
import Testing
@testable import MaryFoundation
import MaryFoundationTestSupport

@Suite struct RecipeSkillShapeTests {

    /// Mirrors `AbilityStudioAuthoringDocument.addRecipeSkill`: a workflow Skill
    /// in the ability's namespace, seamless, with its first step already placed
    /// and its own invocation name.
    private func recipeSkill(
        abilityID: String = "tests.editor",
        steps: [WorkflowStepSchema] = [.init(id: "save", operation: "save_document")],
        access: SkillAccess = .seamless,
        kind: SkillKind = .workflow,
        invocation: String? = "tests_editor_tidy_up"
    ) -> SkillSchema {
        SkillSchema(
            id: SkillID("\(abilityID).tidy-up"),
            title: "Tidy up",
            summary: "Runs Tidy up as one step.",
            kind: kind,
            access: access,
            execution: .init(kind: .stateMachine, steps: steps),
            modelExposure: .init(
                invocationName: invocation,
                inheritsBindingContract: false),
            usesStage: false,
            timeoutSeconds: 60)
    }

    private func packageOwning(_ skill: SkillSchema) -> MaryAbilityPackage {
        var package = PackageFixtures.applicationExpertise
        package.skills.append(skill)
        package.ability.skills.append(skill.id)
        return package
    }

    private func errors(_ package: MaryAbilityPackage) -> [SchemaIssue] {
        AbilityPackageValidator.validateGraph([package])
            .issues
            .filter { $0.severity == .error }
    }

    @Test func theShapeTheStudioWritesValidates() {
        let issues = errors(packageOwning(recipeSkill()))
        #expect(issues.isEmpty, "unexpected: \(issues.map(\.code))")
    }

    @Test func aRecipeWithNoStepsIsRefused() {
        let issues = errors(packageOwning(recipeSkill(steps: [])))
        #expect(issues.contains { $0.code == "missing-workflow" })
    }

    /// The runtime refuses to cross a confirmation boundary mid-workflow, so the
    /// Studio never offers `confirm` for a recipe.
    @Test func aRecipeThatStopsToAskIsRefused() {
        let issues = errors(packageOwning(recipeSkill(access: .confirm)))
        #expect(!issues.isEmpty)
    }

    /// `.stateMachine` execution and `.workflow` kind are one decision.
    @Test func aStateMachineMustBeAWorkflowKind() {
        let issues = errors(packageOwning(recipeSkill(kind: .effectful)))
        #expect(!issues.isEmpty)
    }

    @Test func aRecipeWithoutAnInvocationNameIsRefused() {
        let issues = errors(packageOwning(recipeSkill(invocation: nil)))
        #expect(!issues.isEmpty)
    }

    /// Steps name callables in snake_case; the id beside them is a schema
    /// identifier, which is a different alphabet. The Studio derives one from
    /// the other rather than reusing it.
    @Test func aStepOperationMustBeSnakeCase() {
        let issues = errors(packageOwning(recipeSkill(
            steps: [.init(id: "save", operation: "Save-Document")])))
        #expect(issues.contains { $0.code == "invalid-workflow-operation" })
    }

    @Test func aStepMayNotComposeARuntimePrimitive() {
        for reserved in RuntimePrimitiveOperations.names {
            let issues = errors(packageOwning(recipeSkill(
                steps: [.init(id: "step", operation: reserved)])))
            #expect(
                issues.contains { $0.code == "reserved-runtime-operation" },
                "\(reserved) should not be composable")
        }
    }

    /// Sequential fallthrough is what makes row order the whole story: a step
    /// with no `onSuccess` is valid and runs the next one.
    @Test func aLinearChainNeedsNoTransitions() {
        let issues = errors(packageOwning(recipeSkill(steps: [
            .init(id: "open", operation: "open_player"),
            .init(id: "play", operation: "play_playlist"),
        ])))
        #expect(issues.isEmpty, "unexpected: \(issues.map(\.code))")
    }

    @Test func aTransitionMustNameAStepThatExists() {
        let issues = errors(packageOwning(recipeSkill(steps: [
            .init(id: "open", operation: "open_player", onSuccess: "gone"),
        ])))
        #expect(issues.contains { $0.code == "unknown-workflow-transition" })
    }

    /// A skill id is namespaced by its ABILITY, not its package — the Studio
    /// derives recipe ids from `ability.id` for exactly this rule.
    @Test func aRecipeIdOutsideTheAbilityNamespaceIsRefused() {
        let issues = errors(packageOwning(recipeSkill(abilityID: "somewhere.else")))
        #expect(!issues.isEmpty)
    }
}

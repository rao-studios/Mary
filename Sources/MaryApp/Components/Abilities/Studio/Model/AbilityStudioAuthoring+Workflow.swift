//
//  AbilityStudioAuthoring+Workflow.swift
//  Mary
//
//  WHAT: Recipes — create one, and add/move/remove the steps that chain skills.
//  IN:   Recipe pane.
//  OUT:  updateSkill → commit, so every edit is graph-validated before it lands.
//  PIN:  A recipe is a Skill (`.stateMachine`), not a new concept. Sequential
//        order alone drives it: a step with no `onSuccess` falls through to the
//        next one, so reordering rows never rewrites a transition.
//

import MaryBrain
import Foundation

/// Snake_case callable names, mirroring `PluginValidator.callableNameIsValid`.
/// Checked here so a bad name is refused in the field rather than at commit.
enum AbilityStudioInvocationName {
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.first?.isLowercase == true,
              value.last != "_",
              !value.contains("__")
        else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }

    /// A name the runtime owns and no package may call or claim.
    static func isReserved(_ value: String) -> Bool {
        RuntimePrimitiveOperations.contains(value)
    }
}

extension AbilityStudioAuthoringDocument {

    // MARK: - Recipes

    var recipes: [SkillSchema] {
        package.skills.filter { $0.execution.kind == .stateMachine }
    }

    /// Create a recipe with its first step already in place. The validator
    /// refuses a state machine with no steps, so there is no empty recipe to
    /// create and fill in afterwards.
    ///
    /// `reservedInvocations` is the set of names the active registry already
    /// answers to. Snapshot lookup is first-wins, so a duplicate would shadow
    /// an installed skill rather than fail loudly.
    @discardableResult
    mutating func addRecipeSkill(
        title: String,
        firstOperation: String,
        reservedInvocations: Set<String> = []
    ) throws -> SkillID {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = firstOperation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AbilityStudioInvocationName.isValid(operation),
              !AbilityStudioInvocationName.isReserved(operation)
        else {
            throw AbilityStudioAuthoringError.invalidInvocationName(operation)
        }

        // Skills live in their ability's namespace, not their package's.
        let abilityID = package.ability.id.rawValue
        let stem = AbilityStudioPackageFactory.portableStem(trimmed, fallback: "recipe")
        let ownedSkills = Set(package.skills.map(\.id.rawValue))
        var skillID = SkillID("\(abilityID).\(stem)")
        if ownedSkills.contains(skillID.rawValue) {
            let suffix = abilityStudioFirstUnusedSuffix {
                ownedSkills.contains("\(abilityID).\(stem)-\($0 + 1)")
            }
            skillID = SkillID("\(abilityID).\(stem)-\(suffix + 1)")
        }

        let prefix = AbilityStudioPackageFactory.callableStem(
            package.package.id.rawValue, fallback: "ability")
        let verb = AbilityStudioPackageFactory.callableStem(trimmed, fallback: "recipe")
        let taken = reservedInvocations
            .union(package.skills.compactMap(\.modelExposure.invocationName))
        var invocation = "\(prefix)_\(verb)"
        if taken.contains(invocation) || AbilityStudioInvocationName.isReserved(invocation) {
            let suffix = abilityStudioFirstUnusedSuffix {
                taken.contains("\(prefix)_\(verb)_\($0 + 1)")
            }
            invocation = "\(prefix)_\(verb)_\(suffix + 1)"
        }

        let skill = SkillSchema(
            id: skillID,
            title: trimmed.isEmpty ? "Recipe" : trimmed,
            summary: "Runs \(trimmed.isEmpty ? "several skills" : trimmed) as one step.",
            kind: .workflow,
            // A recipe may not stop to ask: the runtime refuses to cross a
            // confirmation boundary mid-workflow.
            access: .seamless,
            execution: .init(
                kind: .stateMachine,
                steps: [Self.workflowStep(operation: operation, existing: [])]),
            modelExposure: .init(
                invocationName: invocation,
                inheritsBindingContract: false),
            usesStage: false,
            timeoutSeconds: 60)

        try addSkill(skill)
        return skillID
    }

    // MARK: - Steps

    /// A step id is a schema identifier — lower-case letters, digits, dots and
    /// hyphens — so it is derived from the operation rather than copied from it.
    static func workflowStep(
        operation: String,
        existing: [WorkflowStepSchema]
    ) -> WorkflowStepSchema {
        let stem = AbilityStudioPackageFactory.portableStem(operation, fallback: "step")
        let owned = Set(existing.map(\.id))
        var id = stem
        if owned.contains(id) {
            id = abilityStudioFirstUnusedName(stem: stem, existing: owned)
        }
        return WorkflowStepSchema(id: id, operation: operation)
    }

    /// True when order alone drives the machine: nothing recovers on failure and
    /// every success either falls through or points at the next step. Only a
    /// linear recipe may be reordered from the pane.
    static func isLinear(_ steps: [WorkflowStepSchema]) -> Bool {
        for (index, step) in steps.enumerated() {
            if step.onFailure != nil { return false }
            guard let onSuccess = step.onSuccess else { continue }
            let next = index + 1 < steps.count ? steps[index + 1].id : nil
            if onSuccess != next { return false }
        }
        return true
    }

    /// Rewrite a linear chain so its transitions match its order again. Called
    /// only when the chain was linear before the edit.
    static func relinkLinearChain(_ steps: inout [WorkflowStepSchema]) {
        for index in steps.indices {
            let declared = steps[index].onSuccess != nil
            steps[index].onSuccess = declared && index + 1 < steps.count
                ? steps[index + 1].id
                : nil
        }
    }

    @discardableResult
    mutating func addWorkflowStep(
        operation: String,
        to skillID: SkillID,
        at index: Int? = nil,
        ownerPackage: MaryAbilityPackage? = nil
    ) throws -> String {
        let trimmed = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AbilityStudioInvocationName.isValid(trimmed),
              !AbilityStudioInvocationName.isReserved(trimmed)
        else {
            throw AbilityStudioAuthoringError.invalidInvocationName(trimmed)
        }
        var createdID = ""
        try commit { candidate in
            guard let position = candidate.skills.firstIndex(where: { $0.id == skillID }) else {
                throw AbilityStudioAuthoringError.recipeNotFound(skillID)
            }
            var steps = candidate.skills[position].execution.steps
            let wasLinear = Self.isLinear(steps)
            let step = Self.workflowStep(operation: trimmed, existing: steps)
            createdID = step.id
            let bounded = max(0, min(index ?? steps.count, steps.count))
            steps.insert(step, at: bounded)
            if wasLinear { Self.relinkLinearChain(&steps) }
            candidate.skills[position].execution.steps = steps
            // Reaching another package's skill declares an OPTIONAL dependency.
            // Requiring it would change which disciplines an expertise extends.
            Self.ensureDependency(on: ownerPackage, required: false, in: &candidate)
        }
        return createdID
    }

    /// Point an existing row at a different skill, declaring the optional
    /// dependency in the same transaction so a retargeted row is never left
    /// naming a package this one does not admit to needing.
    mutating func retargetWorkflowStep(
        _ stepID: String,
        in skillID: SkillID,
        to operation: String,
        ownerPackage: MaryAbilityPackage?
    ) throws {
        let trimmed = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AbilityStudioInvocationName.isValid(trimmed),
              !AbilityStudioInvocationName.isReserved(trimmed)
        else {
            throw AbilityStudioAuthoringError.invalidInvocationName(trimmed)
        }
        try commit { candidate in
            guard let position = candidate.skills.firstIndex(where: { $0.id == skillID }) else {
                throw AbilityStudioAuthoringError.recipeNotFound(skillID)
            }
            guard let index = candidate.skills[position].execution.steps
                .firstIndex(where: { $0.id == stepID })
            else {
                throw AbilityStudioAuthoringError.workflowStepNotFound(stepID)
            }
            candidate.skills[position].execution.steps[index].operation = trimmed
            Self.ensureDependency(on: ownerPackage, required: false, in: &candidate)
        }
    }

    mutating func updateWorkflowStep(
        _ stepID: String,
        in skillID: SkillID,
        _ transform: (inout WorkflowStepSchema) -> Void
    ) throws {
        try commit { candidate in
            guard let position = candidate.skills.firstIndex(where: { $0.id == skillID }) else {
                throw AbilityStudioAuthoringError.recipeNotFound(skillID)
            }
            var steps = candidate.skills[position].execution.steps
            guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
                throw AbilityStudioAuthoringError.workflowStepNotFound(stepID)
            }
            let previous = steps[index].id
            transform(&steps[index])
            let next = steps[index].id
            if next != previous {
                guard !steps.enumerated().contains(where: {
                    $0.offset != index && $0.element.id == next
                }) else {
                    throw AbilityStudioAuthoringError.workflowStepNotFound(next)
                }
                // A renamed step is still the target of whatever pointed at it.
                for other in steps.indices {
                    if steps[other].onSuccess == previous { steps[other].onSuccess = next }
                    if steps[other].onFailure == previous { steps[other].onFailure = next }
                }
            }
            candidate.skills[position].execution.steps = steps
        }
    }

    mutating func moveWorkflowStep(
        _ stepID: String,
        in skillID: SkillID,
        to destination: Int
    ) throws {
        try commit { candidate in
            guard let position = candidate.skills.firstIndex(where: { $0.id == skillID }) else {
                throw AbilityStudioAuthoringError.recipeNotFound(skillID)
            }
            var steps = candidate.skills[position].execution.steps
            guard Self.isLinear(steps) else {
                throw AbilityStudioAuthoringError.workflowIsBranching(skillID)
            }
            guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
                throw AbilityStudioAuthoringError.workflowStepNotFound(stepID)
            }
            let step = steps.remove(at: index)
            steps.insert(step, at: max(0, min(destination, steps.count)))
            Self.relinkLinearChain(&steps)
            candidate.skills[position].execution.steps = steps
        }
    }

    mutating func removeWorkflowStep(
        _ stepID: String,
        from skillID: SkillID
    ) throws {
        guard let skill = package.skills.first(where: { $0.id == skillID }) else {
            throw AbilityStudioAuthoringError.recipeNotFound(skillID)
        }
        // The validator refuses an empty state machine, so the last step can
        // only leave with the recipe itself.
        guard skill.execution.steps.count > 1 else {
            throw AbilityStudioAuthoringError.cannotRemoveLastWorkflowStep(skillID)
        }
        try commit { candidate in
            guard let position = candidate.skills.firstIndex(where: { $0.id == skillID }) else {
                throw AbilityStudioAuthoringError.recipeNotFound(skillID)
            }
            var steps = candidate.skills[position].execution.steps
            let wasLinear = Self.isLinear(steps)
            steps.removeAll { $0.id == stepID }
            // A transition into a step that no longer exists is a validation
            // error, so it degrades to falling through.
            for index in steps.indices {
                if steps[index].onSuccess == stepID { steps[index].onSuccess = nil }
                if steps[index].onFailure == stepID { steps[index].onFailure = nil }
            }
            if wasLinear { Self.relinkLinearChain(&steps) }
            candidate.skills[position].execution.steps = steps
        }
    }

    /// Naming a supporting ability means Mary must have it installed to act, so
    /// the package says it depends on it — optionally, because supporting is
    /// not the same claim as realizing.
    mutating func declareSupportingDependency(on ownerPackage: MaryAbilityPackage) throws {
        try commit { candidate in
            Self.ensureDependency(on: ownerPackage, required: false, in: &candidate)
        }
    }

    // MARK: - Fixtures

    /// A routing fixture is a whole sentence the author states this skill should
    /// answer. It is also the only lever that moves the skill embedding tier.
    mutating func addFixture(
        utterance: String,
        expectedSkill: SkillID?
    ) throws {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try commit { candidate in
            guard !candidate.fixtures.contains(where: {
                $0.utterance.caseInsensitiveCompare(trimmed) == .orderedSame
            }) else { return }
            let stem = AbilityStudioPackageFactory.portableStem(trimmed, fallback: "fixture")
            let owned = Set(candidate.fixtures.map(\.id))
            let id = owned.contains(stem)
                ? abilityStudioFirstUnusedName(stem: stem, existing: owned)
                : stem
            candidate.fixtures.append(.init(
                id: String(id.prefix(80)),
                utterance: trimmed,
                expectedSkill: expectedSkill,
                expectedDisposition: "route"))
        }
    }
}

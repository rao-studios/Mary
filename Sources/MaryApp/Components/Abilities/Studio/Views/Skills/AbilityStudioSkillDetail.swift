//
//  AbilityStudioSkillDetail.swift
//  Mary
//
//  WHAT: The selected skill, close up — and what can be done with it.
//  IN:   AbilityStudioSkillsPane selection.
//  OUT:  addWorkflowStep, transitionSkillKind, updateSkill.
//  PIN:  Replaces the six numbered blocks of the old Skill card. Everything cut
//        is still reachable — under More, or in the Advanced drawer.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioSkillDetail: View {
    @ObservedObject var model: AbilityStudioViewModel
    let tile: AbilityStudioSkillTile
    let draft: MaryAbilityPackage
    let onOpenOwner: (AbilityID) -> Void

    private var isOwn: Bool { tile.origin == .own }
    private var ownSkill: SkillSchema? {
        draft.skills.first { $0.id == tile.id }
    }

    /// This package can realize a dependency-owned portable skill when the
    /// coverage read says the contract is satisfiable by bounded hands.
    private var implementation: AbilityStudioActionCoveragePresentation.PortableSkillOption? {
        guard case .none = tile.realization else { return nil }
        return AbilityStudioActionCoveragePresentation(
            package: draft,
            snapshot: model.snapshot)
            .implementationOptions
            .first { $0.skillID == tile.id }
    }

    /// A recipe cannot call something that asks the user, nor itself.
    private var canAddToRecipe: Bool {
        guard let recipe = model.selectedRecipe, let invocation = tile.invocation else {
            return false
        }
        guard tile.isComposable else { return false }
        guard tile.id != recipe.id else { return false }
        return !recipe.execution.steps.contains { $0.operation == invocation }
    }

    private var addToRecipeReason: String {
        guard model.selectedRecipe != nil else { return "Add a recipe first." }
        guard tile.invocation != nil else { return "This skill has no callable name." }
        guard tile.isComposable else {
            return "A recipe cannot call a skill that stops to ask the user."
        }
        guard tile.id != model.selectedRecipe?.id else { return "A recipe cannot call itself." }
        return "Already a step in this recipe."
    }

    var body: some View {
        MaryCard(padding: .layer3) {
            VStack(alignment: .leading, spacing: .layer3) {
                header
                if !tile.summary.isEmpty {
                    Text(tile.summary)
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                facts
                actions
            }
        }
    }

    private var header: some View {
        HStack(spacing: .layer2) {
            Circle()
                .fill(Color.maryAbilityTint(tile.ownerTint))
                .frame(width: 9, height: 9)
            Text(tile.title)
                .font(.marySerif(14, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            if let invocation = tile.invocation {
                Text(invocation)
                    .font(.maryMono(10))
                    .foregroundStyle(Color.maryInk.opacity(0.5))
            }
            Spacer(minLength: .layer2)
            if let readiness = tile.readiness {
                MaryBadge(
                    text: AbilityStudioLabels.readinessWord(readiness),
                    color: AbilityStudioLabels.readinessColor(readiness))
            }
        }
    }

    private var facts: some View {
        FlowLayout(spacing: .layer1) {
            fact(AbilityStudioLabels.kindWord(tile.kind))
            fact(AbilityStudioLabels.accessWord(tile.access))
            if !tile.realization.word.isEmpty {
                fact(tile.realization.word)
            }
            if case .extendedDiscipline = tile.origin {
                fact("from \(tile.ownerTitle)")
            }
            if case .supporting = tile.origin {
                fact("supporting · \(tile.ownerTitle)")
            }
        }
    }

    private func fact(_ text: String) -> some View {
        Text(text)
            .font(.marySans(10))
            .foregroundStyle(Color.maryInk.opacity(0.62))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.maryInk.opacity(0.05)))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var actions: some View {
        HStack(spacing: .layer2) {
            Button("Use in recipe", action: addToRecipe)
                .buttonStyle(.maryQuiet)
                .font(.marySans(11))
                .disabled(!canAddToRecipe)
                .opacity(canAddToRecipe ? 1 : 0.4)
                .help(canAddToRecipe
                      ? "Append this skill as the recipe's next step."
                      : addToRecipeReason)

            if let implementation {
                Button("Give it hands") { giveHands(implementation) }
                    .buttonStyle(.maryQuiet)
                    .font(.marySans(11))
                    .disabled(!implementation.compatibility.canImplement)
                    .opacity(implementation.compatibility.canImplement ? 1 : 0.4)
                    .help(implementation.compatibility.reason
                          ?? "Create a local recipe in this ability that carries out \(tile.title).")
            }

            if !isOwn {
                Button("Open \(tile.ownerTitle)") { onOpenOwner(tile.ownerAbilityID) }
                    .buttonStyle(.maryQuiet)
                    .font(.marySans(11))
            }

            Spacer(minLength: 0)

            if isOwn, let skill = ownSkill, skill.execution.kind == .stateMachine {
                Button("Remove recipe") { remove(skill) }
                    .buttonStyle(.plain)
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryError.opacity(0.8))
            }
        }
    }

    private func addToRecipe() {
        guard let recipe = model.selectedRecipe, let invocation = tile.invocation else { return }
        model.mutateAuthoringDocument { document in
            try document.addWorkflowStep(
                operation: invocation,
                to: recipe.id,
                ownerPackage: model.ownerPackage(forInvocation: invocation))
        }
    }

    /// Seeds one starter block and lets the author fill in the rest in the
    /// recipe row. A skill that can act needs a real gesture; one that only
    /// verifies gets a bounded wait.
    private func giveHands(
        _ option: AbilityStudioActionCoveragePresentation.PortableSkillOption
    ) {
        guard option.compatibility.canImplement,
              let owner = model.snapshot.package(id: option.ownerPackageID)?.package
        else { return }
        let starter: PluginRecipeStepSchema
        switch option.compatibility.starter {
        case .keyChord:
            // No chord is guessed here — an unfilled key is visibly unfinished,
            // which is better than a plausible wrong one.
            starter = .init(id: "perform", kind: .keyChord, key: .a)
        case .boundedVerification, nil:
            starter = .init(id: "verify", kind: .wait, durationSeconds: 0.1)
        }
        model.mutateAuthoringDocument { document in
            _ = try document.addPluginOperation(
                title: option.skillTitle,
                summary: option.summary,
                steps: [starter],
                realizing: option.skillID,
                ownerPackage: owner,
                targetClasses: option.compatibility.targetClasses)
        }
    }

    private func remove(_ skill: SkillSchema) {
        let removed = model.mutateAuthoringDocument { document in
            try document.removeSkill(skill.id)
        }
        if removed, model.selectedRecipeID == skill.id {
            model.selectedRecipeID = nil
        }
        model.selectedSkillID = nil
    }
}

//
//  AbilityStudioViewModel+Studio.swift
//  Mary
//
//  WHAT: What the panes read — recipes, rows, autocomplete.
//  IN:   AbilityStudioView panes.
//  OUT:  pure computations over (draftPackage, snapshot). No writes here.
//

import MaryBrain
import Foundation

extension AbilityStudioViewModel {

    /// Recipes come from the draft, never the snapshot: the registry still
    /// holds the last saved copy of this same package.
    var recipes: [SkillSchema] {
        draftPackage?.skills.filter { $0.execution.kind == .stateMachine } ?? []
    }

    /// The chosen recipe, or the first one when the selection is stale — a
    /// removed recipe should not empty the pane.
    var selectedRecipe: SkillSchema? {
        let all = recipes
        if let selectedRecipeID, let match = all.first(where: { $0.id == selectedRecipeID }) {
            return match
        }
        return all.first
    }

    var recipeResolver: AbilityStudioRecipeResolver? {
        guard let draftPackage else { return nil }
        return AbilityStudioRecipeResolver(draft: draftPackage, snapshot: snapshot)
    }

    var recipeRows: [AbilityStudioRecipeRow] {
        guard let recipe = selectedRecipe, let resolver = recipeResolver else { return [] }
        return resolver.rows(for: recipe)
    }

    /// Only a linear recipe may be reordered from the pane; one with real
    /// failure branches keeps its order and is edited in Advanced.
    var selectedRecipeIsLinear: Bool {
        guard let recipe = selectedRecipe else { return true }
        return AbilityStudioAuthoringDocument.isLinear(recipe.execution.steps)
    }

    var invocationCatalog: AbilityStudioInvocationCatalog? {
        guard let draftPackage else { return nil }
        return AbilityStudioInvocationCatalog(
            draft: draftPackage,
            excludingRecipe: selectedRecipe?.id,
            snapshot: snapshot)
    }

    /// Invocation names the active registry already answers to. A new recipe
    /// must not shadow one, because snapshot lookup is first-wins.
    var reservedInvocations: Set<String> {
        Set(snapshot.skills.compactMap { runtime in
            runtime.packageID == draftPackage?.package.id
                ? nil
                : runtime.skill.modelExposure.invocationName
        })
    }

    /// The installed package that owns an invocation, so a committed step can
    /// declare the optional dependency that reaching it implies.
    func ownerPackage(forInvocation invocation: String) -> MaryAbilityPackage? {
        guard let runtime = snapshot.skill(invocationName: invocation),
              runtime.packageID != draftPackage?.package.id
        else { return nil }
        return snapshot.package(id: runtime.packageID)?.package
    }
}

//
//  AbilityStudioRecipePane.swift
//  Mary
//
//  WHAT: The recipes an ability owns, and the steps that chain skills into one.
//  IN:   AbilityStudioView.
//  OUT:  addRecipeSkill / addWorkflowStep through the authoring document.
//  PIN:  A recipe is a Skill with its own invocation name, so the router can
//        pick one straight from an utterance. Many per ability is the point.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioRecipePane: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    @State private var showsNewRecipe = false
    @State private var newRecipeTitle = ""
    @State private var newRecipeStep = ""
    @State private var pendingStep = ""
    @State private var showsPendingRow = false

    private var recipes: [SkillSchema] { model.recipes }
    private var recipe: SkillSchema? { model.selectedRecipe }
    private var rows: [AbilityStudioRecipeRow] { model.recipeRows }

    var body: some View {
        StudioPane("Recipe") {
            recipeChips
        } content: {
            if let recipe, let catalog = model.invocationCatalog {
                steps(recipe, catalog: catalog)
            } else {
                emptyState
            }
        }
    }

    // MARK: - Chips

    @ViewBuilder
    private var recipeChips: some View {
        HStack(spacing: .layer1) {
            ForEach(recipes, id: \.id) { item in
                MaryChip(
                    label: item.title,
                    isOn: item.id == recipe?.id
                ) {
                    model.selectedRecipeID = item.id
                    model.expandedRecipeStepID = nil
                }
            }
            if !recipes.isEmpty {
                StudioAddButton(title: "Recipe") { openNewRecipe() }
            }
        }
        .popover(isPresented: $showsNewRecipe, arrowEdge: .bottom) {
            newRecipeForm
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private func steps(
        _ recipe: SkillSchema,
        catalog: AbilityStudioInvocationCatalog
    ) -> some View {
        let canReorder = model.selectedRecipeIsLinear
        VStack(alignment: .leading, spacing: .layer2) {
            if !canReorder {
                HStack(spacing: .layer2) {
                    MaryBadge(text: "branching", color: .maryGold)
                    StudioNote("This recipe recovers on failure, so its order is edited in Advanced.")
                }
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AbilityStudioRecipeRowView(
                    model: model,
                    row: row,
                    recipeID: recipe.id,
                    catalog: catalog,
                    isLast: index == rows.count - 1,
                    canReorder: canReorder,
                    expandedStepID: Binding(
                        get: { model.expandedRecipeStepID },
                        set: { model.expandedRecipeStepID = $0 }))
            }

            if showsPendingRow {
                pendingRow(recipe: recipe, catalog: catalog)
            } else {
                StudioAddButton(title: "Step") {
                    pendingStep = ""
                    showsPendingRow = true
                }
                .padding(.leading, 19)
            }

            Spacer(minLength: .layer2)

            inputs(recipe)
        }
    }

    /// A row being named is view state only. Nothing is written until a name
    /// resolves, so an abandoned row leaves no trace in the package.
    private func pendingRow(
        recipe: SkillSchema,
        catalog: AbilityStudioInvocationCatalog
    ) -> some View {
        HStack(spacing: .layer2) {
            Text("\(rows.count + 1)")
                .font(.maryMono(10))
                .foregroundStyle(Color.maryInk.opacity(0.2))
                .frame(width: 13, alignment: .trailing)
            StudioPill {
                TextField("name a skill…", text: $pendingStep)
                    .textFieldStyle(.plain)
                    .font(.maryMono(12))
                    .foregroundStyle(Color.maryInk)
                    .onSubmit { addPendingStep(to: recipe, catalog: catalog) }
                Spacer(minLength: .layer1)
                Circle()
                    .fill(Color.maryInk.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
            Button("Cancel") { showsPendingRow = false }
                .buttonStyle(.plain)
                .font(.marySans(10))
                .foregroundStyle(Color.maryInk.opacity(0.4))
        }
    }

    @ViewBuilder
    private func inputs(_ recipe: SkillSchema) -> some View {
        let parameters = recipe.modelExposure.parameters
        VStack(alignment: .leading, spacing: .layer2) {
            Divider().overlay(Color.maryBorder)
            HStack(alignment: .top, spacing: .layer2) {
                StudioLabel("Asks for")
                if parameters.isEmpty {
                    StudioNote("Nothing — this recipe runs on its own.")
                } else {
                    FlowLayout(spacing: .layer1) {
                        ForEach(parameters, id: \.name) { parameter in
                            Text("\(parameter.name) · \(parameter.type)\(parameter.required ? " · required" : "")")
                                .font(.maryMono(10))
                                .foregroundStyle(Color.maryInk.opacity(0.7))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.maryInk.opacity(0.06)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            Spacer(minLength: .layer5)
            HStack {
                Spacer()
                VStack(spacing: .layer3) {
                    MaryEmblem(iconSize: 46)
                    Text("No recipe yet")
                        .font(.marySerif(17, weight: .light, italic: true))
                        .foregroundStyle(Color.maryInk)
                    Text("A recipe chains skills into one step Mary can be asked for directly — this ability's own, or any installed ability's.")
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    Button("Add a recipe") { openNewRecipe() }
                        .buttonStyle(.mary)
                }
                Spacer()
            }
            Spacer(minLength: .layer5)
        }
        .popover(isPresented: $showsNewRecipe, arrowEdge: .top) {
            newRecipeForm
        }
    }

    // MARK: - New recipe

    /// The validator refuses a state machine with no steps, so creation asks for
    /// the first one rather than making an empty recipe to fill in later.
    private var newRecipeForm: some View {
        VStack(alignment: .leading, spacing: .layer3) {
            Text("New recipe")
                .font(.marySerif(15, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            StudioField("Called", value: newRecipeTitle, placeholder: "Play my mix") {
                newRecipeTitle = $0
            }
            StudioField(
                "First step",
                value: newRecipeStep,
                placeholder: "open_player",
                mono: true
            ) { newRecipeStep = $0 }
            StudioNote("A recipe needs at least one step, so name the skill it starts with.")
            HStack {
                Spacer()
                Button("Cancel") { showsNewRecipe = false }
                    .buttonStyle(.maryQuiet)
                Button("Create", action: createRecipe)
                    .buttonStyle(.mary)
                    .disabled(!canCreateRecipe)
                    .opacity(canCreateRecipe ? 1 : 0.4)
            }
        }
        .padding(.layer4)
        .frame(width: 320)
        .background(Paper.page)
    }

    private var canCreateRecipe: Bool {
        !newRecipeTitle.trimmingCharacters(in: .whitespaces).isEmpty
            && AbilityStudioInvocationName.isValid(
                newRecipeStep.trimmingCharacters(in: .whitespaces))
    }

    private func openNewRecipe() {
        newRecipeTitle = ""
        newRecipeStep = ""
        showsNewRecipe = true
    }

    private func createRecipe() {
        let title = newRecipeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let step = newRecipeStep.trimmingCharacters(in: .whitespacesAndNewlines)
        var created: SkillID?
        let accepted = model.mutateAuthoringDocument { document in
            created = try document.addRecipeSkill(
                title: title,
                firstOperation: step,
                reservedInvocations: model.reservedInvocations)
        }
        guard accepted else { return }
        model.selectedRecipeID = created
        showsNewRecipe = false
    }

    private func addPendingStep(
        to recipe: SkillSchema,
        catalog: AbilityStudioInvocationCatalog
    ) {
        let operation = pendingStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operation.isEmpty else {
            showsPendingRow = false
            return
        }
        let accepted = model.mutateAuthoringDocument { document in
            try document.addWorkflowStep(
                operation: operation,
                to: recipe.id,
                ownerPackage: model.ownerPackage(forInvocation: operation))
        }
        if accepted {
            showsPendingRow = false
            pendingStep = ""
        }
    }
}

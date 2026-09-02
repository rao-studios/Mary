//
//  AbilityRunCostEstimate.swift
//  Mary
//
//  WHAT: What one run of a recipe is likely to cost.
//  IN:   Ability Studio header.
//  OUT:  pure over resolved recipe rows.
//  PIN:  Only cognitive skills are counted. Workflow-only primitives are
//        deterministic transformations — the runtime says so — and hands cost
//        time, not tokens.
//

import MaryBrain
import Foundation

struct AbilityRunCostEstimate: Equatable {
    /// Steps that will reach the model.
    let modelCalls: Int
    /// Recipe parameters the model has to compose rather than pass through.
    let compositionParameters: Int
    /// Steps whose cost cannot be known because they do not resolve.
    let uncounted: [String]
    /// Steps carried out by hands. Not billed; shown so the readout is honest
    /// about what the recipe actually does.
    let hands: Int

    var total: Int { modelCalls + compositionParameters }

    static let empty = AbilityRunCostEstimate(
        modelCalls: 0, compositionParameters: 0, uncounted: [], hands: 0)

    /// Nested recipes are followed, because a step that calls a recipe pays for
    /// everything that recipe does.
    static func estimate(
        recipe: SkillSchema,
        draft: MaryAbilityPackage,
        resolver: AbilityStudioRecipeResolver
    ) -> AbilityRunCostEstimate {
        var modelCalls = 0
        var hands = 0
        var uncounted: [String] = []
        var visited: Set<SkillID> = []

        func walk(_ skill: SkillSchema, depth: Int) {
            guard depth <= AbilityStudioRecipeResolver.maximumDepth,
                  visited.insert(skill.id).inserted
            else { return }
            for step in skill.execution.steps {
                switch resolver.target(for: step.operation) {
                case .installed(let runtime):
                    if runtime.skill.kind == .cognitive { modelCalls += 1 } else { hands += 1 }
                case .draftSkill(let target):
                    switch target.execution.kind {
                    case .cognitive: modelCalls += 1
                    case .binding: hands += 1
                    case .stateMachine: walk(target, depth: depth + 1)
                    }
                case .primitive:
                    // Deterministic: it transforms what earlier steps produced.
                    break
                case nil:
                    uncounted.append(step.operation)
                }
            }
        }
        walk(recipe, depth: 0)

        return AbilityRunCostEstimate(
            modelCalls: modelCalls,
            compositionParameters: recipe.modelExposure.parameters
                .filter(\.requiresComposition).count,
            uncounted: uncounted,
            hands: hands)
    }

    // MARK: - Reading

    func amount(pricePerCall: Double) -> String {
        (Decimal(total) * Decimal(pricePerCall))
            .formatted(.currency(code: "USD"))
    }

    /// "no model calls · 3 hands". Plain counts, so a free recipe reads as free
    /// rather than as a suspicious zero.
    var detail: String {
        var parts: [String] = []
        parts.append(total == 0
                     ? "no model calls"
                     : total == 1 ? "1 model call" : "\(total) model calls")
        if hands > 0 {
            parts.append(hands == 1 ? "1 hand" : "\(hands) hands")
        }
        if !uncounted.isEmpty {
            parts.append("\(uncounted.count) unresolved")
        }
        return parts.joined(separator: " · ")
    }

    var help: String {
        var lines = ["Estimated for one run of this recipe."]
        if compositionParameters > 0 {
            lines.append("\(compositionParameters) parameter\(compositionParameters == 1 ? "" : "s") the model has to compose.")
        }
        if !uncounted.isEmpty {
            lines.append("Not counted, because they do not resolve: \(uncounted.joined(separator: ", ")).")
        }
        lines.append("Hands cost time, not tokens. Set the price per model call in Settings.")
        return lines.joined(separator: "\n")
    }
}

extension AbilityStudioViewModel {
    var costEstimate: AbilityRunCostEstimate? {
        guard let recipe = selectedRecipe,
              let draftPackage,
              let resolver = recipeResolver
        else { return nil }
        return .estimate(recipe: recipe, draft: draftPackage, resolver: resolver)
    }
}

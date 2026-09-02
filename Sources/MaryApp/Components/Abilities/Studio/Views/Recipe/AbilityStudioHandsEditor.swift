//
//  AbilityStudioHandsEditor.swift
//  Mary
//
//  WHAT: The macUI blocks that carry out one recipe row, in place.
//  IN:   AbilityStudioRecipeRowView expansion.
//  OUT:  AbilityStudioRecipeSequencer (the existing block editor).
//  PIN:  Hands are one level down from the row that uses them, not a stage away.
//

import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioHandsEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let operationIndex: Int
    let operation: String

    private var schema: PluginOperationSchema? {
        guard let plugin = model.draftPackage?.plugin,
              plugin.operations.indices.contains(operationIndex)
        else { return nil }
        return plugin.operations[operationIndex]
    }

    var body: some View {
        if let schema {
            MaryCard(padding: .layer3) {
                VStack(alignment: .leading, spacing: .layer3) {
                    HStack(spacing: .layer2) {
                        Text(schema.operation)
                            .font(.maryMono(10))
                            .foregroundStyle(Color.maryInk.opacity(0.65))
                        Text(schema.title)
                            .font(.marySans(10))
                            .foregroundStyle(Color.maryInk.opacity(0.5))
                        Spacer(minLength: .layer2)
                        MaryBadge(text: "hands here", color: .maryGreen)
                    }

                    AbilityStudioRecipeSequencer(
                        model: model,
                        operation: schema,
                        operationIndex: operationIndex,
                        lane: .action)

                    if !schema.cleanupSteps.isEmpty {
                        Divider().overlay(Color.maryBorder)
                        StudioLabel("Afterwards")
                        AbilityStudioRecipeSequencer(
                            model: model,
                            operation: schema,
                            operationIndex: operationIndex,
                            lane: .cleanup)
                    } else {
                        StudioNote(
                            "Mary restores the user's app, focused surface and pointer after the recipe, whether or not you add cleanup.")
                    }
                }
            }
        }
    }
}

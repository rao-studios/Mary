import MaryBrain
import SwiftUI

// MARK: - Visual recipe blocks

/// Who owns the sequenced steps. One case: a callable operation (`schemaPath` names the array).
enum AbilityStudioRecipeOwner: Hashable {
    case callable(operation: String, index: Int)

    var operation: String {
        switch self {
        case .callable(let operation, _):
            return operation
        }
    }

    var schemaPath: String {
        switch self {
        case .callable(_, let index):
            return "plugin.operations[\(index)]"
        }
    }
}

@MainActor
struct AbilityStudioRecipeSequencer: View {
    @ObservedObject var model: AbilityStudioViewModel
    let operation: PluginOperationSchema
    let owner: AbilityStudioRecipeOwner
    var lane: AbilityStudioRecipeLane = .action
    var planOwnedCoordinateSpaces: [String] = []

    init(
        model: AbilityStudioViewModel,
        operation: PluginOperationSchema,
        operationIndex: Int,
        lane: AbilityStudioRecipeLane = .action
    ) {
        self.model = model
        self.operation = operation
        owner = .callable(operation: operation.operation, index: operationIndex)
        self.lane = lane
    }

    private var steps: [PluginRecipeStepSchema] { lane.steps(in: operation) }
    private var authorableKinds: [PluginRecipeStepKind] {
        if lane == .cleanup { return [.keyChord, .wait] }
        // Authorable steps are what the executor can perform (compiler refuses pointer).
        return PluginRecipeStepKind.authorableCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                if let index = steps.firstIndex(where: {
                    $0.id == step.id
                }) {
                    AbilityStudioRecipeStepCard(
                        model: model,
                        operation: operation,
                        owner: owner,
                        lane: lane,
                        step: step,
                        stepIndex: index,
                        planOwnedCoordinateSpaces: planOwnedCoordinateSpaces)
                }
            }
            if steps.isEmpty, lane == .cleanup {
                Label(
                    "No cleanup needed. Mary still restores the user's app, focused surface, and pointer after the recipe.",
                    systemImage: "arrow.uturn.backward.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Menu(lane == .cleanup ? "Add Cleanup Block" : "Add Block") {
                ForEach(authorableKinds, id: \.self) { kind in
                    Button(kind.editorTitle) { add(kind) }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func add(_ kind: PluginRecipeStepKind) {
        let id = abilityStudioFirstUnusedName(
            stem: lane == .cleanup ? "cleanup" : "step",
            existing: steps.map(\.id))
        // No seeded defaults; design-lane chords/pointer steps are gone.
        let step = PluginRecipeStepSchema.editorDefault(kind: kind, id: id)
        switch owner {
        case .callable:
            model.mutateAuthoringDocument {
                try $0.addStep(step, to: operation.operation, lane: lane)
            }
        }
    }
}

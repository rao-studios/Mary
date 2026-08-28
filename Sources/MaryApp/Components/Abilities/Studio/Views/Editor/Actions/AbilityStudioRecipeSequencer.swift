import MaryBrain
import SwiftUI

// MARK: - Visual recipe blocks

/// WHO OWNS THE STEPS being sequenced.
///
/// ONE CASE, AND IT USED TO BE TWO. The second was `designTemplate` — steps
/// belonging to a semantic design plan's private template, edited through a
/// separate integrity type and written to `plugin.designPlan`. Mary's package
/// grammar has no design plan, so a callable operation is the only thing that
/// can own a recipe here. An enum with one case is a struct wearing a costume,
/// but this one keeps its shape deliberately: it is the seam the design lane
/// would return through, and its `schemaPath` still has to say which of a
/// package's arrays the steps live in.
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
        // THE POINTER BRANCH WENT WITH THE DESIGN LANE. A surface-navigation
        // template could author pointer moves and clicks; nothing else could,
        // and Mary's compiler refuses pointer steps at compile time anyway
        // (`PluginCompiledStep`, `.pointerUnavailable`). What is authorable
        // here is what the executor can actually perform.
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
        // NO SEEDED DEFAULTS. The two that stood here — ⌃⇥ for a
        // navigation template's chord, and a centred pointer step
        // against the last captured anchor — were both design-lane, and
        // the pointer one authored a step the compiler refuses.
        let step = PluginRecipeStepSchema.editorDefault(kind: kind, id: id)
        switch owner {
        case .callable:
            model.mutateAuthoringDocument {
                try $0.addStep(step, to: operation.operation, lane: lane)
            }
        }
    }
}

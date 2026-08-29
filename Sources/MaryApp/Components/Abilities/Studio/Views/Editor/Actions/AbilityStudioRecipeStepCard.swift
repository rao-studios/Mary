import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioRecipeStepCard: View {
    @ObservedObject var model: AbilityStudioViewModel
    let operation: PluginOperationSchema
    let owner: AbilityStudioRecipeOwner
    let lane: AbilityStudioRecipeLane
    let step: PluginRecipeStepSchema
    let stepIndex: Int
    var planOwnedCoordinateSpaces: [String] = []

    var laneSteps: [PluginRecipeStepSchema] { lane.steps(in: operation) }
    func coordinateInputNames(positive: Bool) -> [String] {
        operation.inputs.compactMap {
            guard [.number, .integer].contains($0.kind),
                  let minimum = $0.minimum,
                  let maximum = $0.maximum,
                  positive ? minimum > 0 : minimum >= 0,
                  maximum <= 1 else { return nil }
            return $0.name
        }
    }
    var scrollInputNames: [String] {
        operation.inputs.compactMap {
            guard [.number, .integer].contains($0.kind),
                  let minimum = $0.minimum,
                  let maximum = $0.maximum,
                  minimum >= -10_000,
                  maximum <= 10_000 else { return nil }
            return $0.name
        }
    }
    var textInputNames: [String] {
        operation.inputs.compactMap { $0.kind == .text ? $0.name : nil }
    }
    var lanePath: String {
        lane == .action ? "steps" : "cleanupSteps"
    }
    var stepPath: String {
        "\(owner.schemaPath).\(lanePath)[\(stepIndex)]"
    }
    var availableCoordinateSpaces: [String] {
        guard lane == .action else { return ["content"] }
        var seen: Set<String> = []
        return (["content"] + planOwnedCoordinateSpaces
            + operation.steps.prefix(stepIndex).compactMap(\.captureAnchor))
            .filter { seen.insert($0).inserted }
    }
    var authorableKinds: [PluginRecipeStepKind] {
        if lane == .cleanup { return [.keyChord, .wait] }
        return PluginRecipeStepKind.authorableCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text("\(stepIndex + 1)")
                    .font(.caption.bold().monospacedDigit())
                    .frame(width: 24, height: 24)
                    .background(step.kind.editorColor.opacity(0.17), in: Circle())
                    .foregroundStyle(step.kind.editorColor)
                Image(systemName: step.kind.editorSymbol)
                    .foregroundStyle(step.kind.editorColor)
                Picker("", selection: Binding(
                    get: { step.kind },
                    set: { kind in
                        // THE THREE SEEDED DEFAULTS WERE ALL DESIGN-LANE:
                        // ⌃⇥ for a navigation template's chord, a centred
                        // pointer step against the last captured anchor, and
                        // Escape for a template's cleanup. None can arise in
                        // this cut, so every kind now takes the editor's own
                        // default — one branch instead of four.
                        mutateStep { target in
                            target = .editorDefault(kind: kind, id: target.id)
                        }
                    })) {
                    ForEach(authorableKinds, id: \.self) {
                        Text($0.editorTitle).tag($0)
                    }
                }
                .labelsHidden()
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.plain)
                    .disabled(stepIndex == 0)
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.plain)
                    .disabled(stepIndex == laneSteps.count - 1)
                Button { remove() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            AbilityStudioTextField(
                "Block id",
                path: "\(stepPath).id",
                text: Binding(
                    get: { step.id },
                    set: { value in mutateStep { $0.id = value } }),
                monospaced: true)

            switch step.kind {
            case .keyChord:
                keyChordEditor
            case .typeText:
                textEditor
            case .pointerMove, .pointerClick, .pointerDrag, .pointerSquareDrag:
                unperformableNotice
            case .scroll:
                scrollEditor
            case .rebindFocusedWindow:
                rebindEditor
            case .captureAccessibilityAnchor:
                accessibilityAnchorEditor
            case .wait:
                waitEditor
            }
        }
        .padding(12)
        .background(step.kind.editorColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(step.kind.editorColor.opacity(0.2)))
    }

    /// A step this build can hold but not run.
    ///
    /// THE SWITCH STAYS EXHAUSTIVE, and that is the point of showing this at
    /// all. `PluginRecipeStepKind` still carries the pointer kinds so a
    /// package authored against a build with hands round-trips through Mary
    /// without silently losing steps — which means a package on this machine
    /// CAN contain one, and an editor that crashed or rendered blank on it
    /// would be lying about what the file holds. It is shown, named, and not
    /// offered: `authorableCases` will not add another.
    private var unperformableNotice: some View {
        Label(
            "\(step.kind.editorTitle) needs a pointer. Mary's hands post key chords, text, waits and window rebinds — this block is kept as authored and refused before the stage is taken.",
            systemImage: "hand.raised.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

}

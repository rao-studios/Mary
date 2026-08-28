import MaryBrain
import SwiftUI

/// Stages the complete semantic-role edit locally so selecting `createArtifact`
/// never puts a temporarily alias-less, invalid operation into the canonical
/// draft. Applying remains one reference-safe package mutation.
@MainActor
struct AbilityStudioOperationSemanticsEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let operation: PluginOperationSchema

    @State private var proposedRole: PluginOperationSemantics.Role?
    @State private var proposedAliases: [String]

    init(
        model: AbilityStudioViewModel,
        operation: PluginOperationSchema
    ) {
        self.model = model
        self.operation = operation
        _proposedRole = State(initialValue: operation.semantics?.role)
        _proposedAliases = State(initialValue: operation.semantics?.aliases ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("This closed role and its validated tokens guide model tool selection only after Mary admits the Ability, application, and Skill. They never select or authorize a target. The title and summary above remain inspector metadata and never acquire execution meaning.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Role", selection: Binding(
                get: { proposedRole },
                set: { role in
                    proposedRole = role
                    if role != .createArtifact { proposedAliases = [] }
                })) {
                Text("Unspecified · conservative").tag(Optional<PluginOperationSemantics.Role>.none)
                ForEach(PluginOperationSemantics.Role.allCases, id: \.self) { role in
                    Text(role.studioTitle).tag(Optional(role))
                }
            }
            .frame(maxWidth: 330)

            if let proposedRole {
                Label(proposedRole.studioExplanation, systemImage: proposedRole.studioSymbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Mary will not guess create or mutation meaning from names or prose.",
                    systemImage: "questionmark.diamond")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if proposedRole == .createArtifact {
                AbilityStudioMachineTokenListEditor(
                    title: "Creation synonyms",
                    values: $proposedAliases)
                Text("These exact artifact-kind tokens distinguish creation from later mutation among already-routed callable tools. They never select an application, target, Skill, or private semantic-plan template; they are data, never instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                AbilityStudioSchemaPath("plugin.operations[].semantics")
                Spacer()
                if hasChanges {
                    Button("Reset") { reset() }
                }
                Button("Apply Semantic Role", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || validationMessage != nil)
            }
        }
        .onChange(of: operation.operation) { _, _ in reset() }
        .onChange(of: operation.semantics) { _, semantics in
            proposedRole = semantics?.role
            proposedAliases = semantics?.aliases ?? []
        }
    }

    private var emitsNativeInput: Bool {
        operation.steps.contains { step in
            switch step.kind {
            case .keyChord, .typeText, .pointerMove, .pointerClick,
                 .pointerDrag, .pointerSquareDrag, .scroll:
                return true
            case .rebindFocusedWindow, .captureAccessibilityAnchor, .wait:
                return false
            }
        }
    }

    private var validationMessage: String? {
        switch proposedRole {
        case .createArtifact:
            if proposedAliases.isEmpty {
                return "Add at least one exact creation synonym before applying."
            }
            if !emitsNativeInput {
                return "A creation role needs at least one remote-hand input block."
            }
        case .mutateArtifact:
            if !emitsNativeInput {
                return "A mutation role needs at least one remote-hand input block."
            }
        case .observe:
            if emitsNativeInput {
                return "An observation role cannot contain remote-hand input blocks."
            }
        case .utility, nil:
            break
        }
        return nil
    }

    private var proposedSemantics: PluginOperationSemantics? {
        proposedRole.map {
            .init(
                role: $0,
                aliases: $0 == .createArtifact ? proposedAliases : [])
        }
    }

    private var hasChanges: Bool {
        proposedSemantics != operation.semantics
    }

    private func reset() {
        proposedRole = operation.semantics?.role
        proposedAliases = operation.semantics?.aliases ?? []
    }

    private func apply() {
        guard validationMessage == nil else { return }
        let semantics = proposedSemantics
        model.mutateValidatedEditorPackage {
            try AbilityStudioEditorIntegrity.updatePluginOperation(
                in: &$0,
                operation: operation.operation) {
                    $0.semantics = semantics
                }
        }
    }
}

private struct AbilityStudioMachineTokenListEditor: View {
    let title: String
    @Binding var values: [String]

    @State private var pending = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text("\(values.count)/\(PluginValidator.maximumOperationAliases)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 4) {
                        Text(value).font(.caption.monospaced())
                        Button {
                            values.removeAll { $0 == value }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.bold())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(value)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.purple.opacity(0.1), in: Capsule())
                }
                TextField("artifact token", text: $pending)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .frame(minWidth: 120)
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.link)
                    .disabled(pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            if let message {
                Text(message).font(.caption2).foregroundStyle(.orange)
            } else {
                Text("One lowercase ASCII word: a-z and 0-9, beginning with a letter. Spaces and punctuation are rejected rather than rewritten.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        guard values.count < PluginValidator.maximumOperationAliases else {
            message = "One operation may declare at most \(PluginValidator.maximumOperationAliases) creation synonyms."
            return
        }
        let validation = AbilityStudioMachineToken.validate(pending)
        guard let token = validation.token else {
            message = validation.message
            return
        }
        guard !values.contains(token) else {
            message = "That creation synonym is already present."
            return
        }
        values.append(token)
        pending = ""
        message = nil
    }
}

private extension PluginOperationSemantics.Role {
    var studioTitle: String {
        switch self {
        case .utility: return "Utility"
        case .observe: return "Observe"
        case .createArtifact: return "Create artifact"
        case .mutateArtifact: return "Mutate artifact"
        }
    }

    var studioExplanation: String {
        switch self {
        case .utility:
            return "A bounded application action without create, observe, or artifact-mutation routing semantics."
        case .observe:
            return "Reads or verifies state and therefore cannot emit native input."
        case .createArtifact:
            return "Creates a new artifact whose exact kind must match one creation synonym."
        case .mutateArtifact:
            return "Changes an existing artifact and cannot satisfy a create-shaped request."
        }
    }

    var studioSymbol: String {
        switch self {
        case .utility: return "wrench.and.screwdriver"
        case .observe: return "eye"
        case .createArtifact: return "plus.square.on.square"
        case .mutateArtifact: return "slider.horizontal.3"
        }
    }
}

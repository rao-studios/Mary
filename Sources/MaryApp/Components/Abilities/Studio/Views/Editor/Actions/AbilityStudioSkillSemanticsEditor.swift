import MaryBrain
import SwiftUI

/// Stages the complete artifact-semantics edit locally so selecting `create`
/// never puts a reference-less, invalid declaration into the canonical draft.
/// Applying remains one reference-safe package mutation through `updateSkill`.
@MainActor
struct AbilityStudioSkillSemanticsEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    let skill: SkillSchema

    @State private var proposedRole: SkillSemanticsSchema.ArtifactRole?
    @State private var proposedReference: ValueTypeID?
    @State private var proposedTargets: [String]

    init(
        model: AbilityStudioViewModel,
        package: MaryAbilityPackage,
        skill: SkillSchema
    ) {
        self.model = model
        self.package = package
        self.skill = skill
        _proposedRole = State(initialValue: skill.semantics?.artifactRole)
        _proposedReference = State(initialValue: skill.semantics?.producesReference)
        _proposedTargets = State(initialValue: skill.semantics?.targetParameters ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("A declared artifact role always beats structural inference: the engine reads it instead of reverse-engineering meaning from naming conventions. Leaving it unspecified falls back to inference within the application's declared artifact domain, and to nothing at all when no domain applies.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Artifact role", selection: Binding(
                get: { proposedRole },
                set: { role in
                    proposedRole = role
                    if role != .create { proposedReference = nil }
                    if role != .mutate { proposedTargets = [] }
                })) {
                Text("Unspecified · conservative").tag(Optional<SkillSemanticsSchema.ArtifactRole>.none)
                ForEach(SkillSemanticsSchema.ArtifactRole.allCases, id: \.self) { role in
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
                    "Mary will infer create or mutation meaning structurally, and only inside a declared artifact domain.",
                    systemImage: "questionmark.diamond")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if proposedRole == .create {
                Picker("Produces reference", selection: $proposedReference) {
                    Text("None yet").tag(Optional<ValueTypeID>.none)
                    ForEach(declaredValueTypes, id: \.id) { valueType in
                        Text("\(valueType.title) · \(valueType.id.rawValue)")
                            .tag(Optional(valueType.id))
                    }
                    if let proposedReference,
                       !declaredValueTypes.contains(where: { $0.id == proposedReference }) {
                        Text(proposedReference.rawValue).tag(Optional(proposedReference))
                    }
                }
                .frame(maxWidth: 430)
                Text("The value type the created artifact's reference output carries. It must also be the value type of one of this Skill's output ports; the engine recognizes create-shaped Skills by this, never by a name suffix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if proposedRole == .mutate {
                AbilityStudioTargetParameterListEditor(
                    title: "Target parameters",
                    values: $proposedTargets)
                Text(declaredAimNames.isEmpty
                     ? "Declare a model-exposure parameter or input port first; a target parameter must name one of them."
                     : "Declared parameter and input names: \(declaredAimNames.sorted().joined(separator: ", ")). Each target must name one of these — they aim this Skill at existing artifacts and never select an application or target by themselves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                AbilityStudioSchemaPath("skills[].semantics")
                Spacer()
                if hasChanges {
                    Button("Reset") { reset() }
                }
                Button("Apply Artifact Role", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || validationMessage != nil)
            }
        }
        .onChange(of: skill.id) { _, _ in reset() }
        .onChange(of: skill.semantics) { _, semantics in
            proposedRole = semantics?.artifactRole
            proposedReference = semantics?.producesReference
            proposedTargets = semantics?.targetParameters ?? []
        }
    }

    /// The reference palette: value types declared by this package plus every
    /// declared dependency. The final commit still validates that the choice
    /// names one of this Skill's output port value types.
    private var declaredValueTypes: [ValueTypeSchema] {
        let dependencyIDs = Set(package.dependencies.map(\.packageID))
        let dependencyTypes = model.snapshot.records
            .filter { dependencyIDs.contains($0.package.package.id) }
            .flatMap(\.package.valueTypes)
        var seen = Set<ValueTypeID>()
        return (package.valueTypes + dependencyTypes)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private var declaredAimNames: Set<String> {
        Set(skill.modelExposure.parameters.map(\.name))
            .union(skill.inputs.map(\.name))
    }

    private var validationMessage: String? {
        guard let proposedRole else { return nil }
        switch proposedRole {
        case .create, .mutate, .plan:
            if skill.kind != .effectful {
                return "A \(proposedRole.rawValue) artifact role requires an effectful Skill."
            }
        case .observe, .utility:
            break
        }
        switch proposedRole {
        case .create:
            guard let proposedReference else {
                return "Name the reference value type the created artifact's output carries."
            }
            if !skill.outputs.contains(where: { $0.valueType == proposedReference }) {
                return "Add an output port carrying \(proposedReference.rawValue) before declaring a create role."
            }
        case .mutate:
            if proposedTargets.isEmpty {
                return "Name at least one parameter that aims this Skill at existing artifacts."
            }
            if let missing = proposedTargets.first(where: {
                !declaredAimNames.contains($0)
            }) {
                return "Target parameter \(missing) is not declared by this Skill's model exposure or inputs."
            }
        case .plan, .observe, .utility:
            break
        }
        return nil
    }

    private var proposedSemantics: SkillSemanticsSchema? {
        proposedRole.map {
            .init(
                artifactRole: $0,
                producesReference: $0 == .create ? proposedReference : nil,
                targetParameters: $0 == .mutate ? proposedTargets : [])
        }
    }

    private var hasChanges: Bool {
        proposedSemantics != skill.semantics
    }

    private func reset() {
        proposedRole = skill.semantics?.artifactRole
        proposedReference = skill.semantics?.producesReference
        proposedTargets = skill.semantics?.targetParameters ?? []
    }

    private func apply() {
        guard validationMessage == nil else { return }
        let semantics = proposedSemantics
        model.mutateAuthoringDocument {
            try $0.updateSkill(skill.id) { $0.semantics = semantics }
        }
    }
}

/// The exact lower-case snake_case grammar target parameters use, applied
/// without silently changing token boundaries: whitespace and case are
/// cosmetic; anything else is rejected rather than rewritten.
private struct AbilityStudioTargetParameterListEditor: View {
    let title: String
    @Binding var values: [String]

    @State private var pending = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium))
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
                TextField("parameter_name", text: $pending)
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
                Text("One lowercase snake_case name: a-z and 0-9 words joined by single underscores. Spaces and punctuation are rejected rather than rewritten.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        let candidate = pending
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard candidate.range(
            of: #"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"#,
            options: .regularExpression) != nil else {
            message = "Use one lowercase snake_case name: a-z and 0-9 words joined by single underscores."
            return
        }
        guard !values.contains(candidate) else {
            message = "That target parameter is already present."
            return
        }
        values.append(candidate)
        pending = ""
        message = nil
    }
}

private extension SkillSemanticsSchema.ArtifactRole {
    var studioTitle: String {
        switch self {
        case .create: return "Create artifact"
        case .mutate: return "Mutate artifact"
        case .plan: return "Apply semantic plan"
        case .observe: return "Observe"
        case .utility: return "Utility"
        }
    }

    var studioExplanation: String {
        switch self {
        case .create:
            return "Makes an artifact that did not exist and mints the reference output naming it."
        case .mutate:
            return "Changes existing artifacts that its target parameters aim it at."
        case .plan:
            return "Applies a whole semantic plan through the provider's plan entry."
        case .observe:
            return "Reads without changing anything."
        case .utility:
            return "Neither creates, mutates, nor observes an artifact — explicit beats implied-by-absence."
        }
    }

    var studioSymbol: String {
        switch self {
        case .create: return "plus.square.on.square"
        case .mutate: return "slider.horizontal.3"
        case .plan: return "square.3.layers.3d.down.right"
        case .observe: return "eye"
        case .utility: return "wrench.and.screwdriver"
        }
    }
}

import MaryBrain
import SwiftUI

// MARK: - Capability card

@MainActor
struct AbilityStudioCapabilityCard: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    let capability: CapabilitySchema
    let index: Int

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    AbilityStudioTextField(
                        "Capability id",
                        path: path("id"),
                        text: Binding(
                            get: { capability.id.rawValue },
                            set: { value in rename(value) }),
                        monospaced: true)
                    Picker("Effect", selection: Binding(
                        get: { capability.effect },
                        set: { value in mutate { $0.effect = value } })) {
                        ForEach(CapabilityEffect.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                }
                AbilityStudioTextField("Title", path: path("title"), text: stringBinding(\.title))
                AbilityStudioTextArea("Summary", path: path("summary"), text: stringBinding(\.summary))
                HStack {
                    valueTypePicker("Input type", selection: capability.inputType) {
                        capability, value in capability.inputType = value
                    }
                    valueTypePicker("Output type", selection: capability.outputType) {
                        capability, value in capability.outputType = value
                    }
                }
                permissionEditor
                constraintEditor
                HStack {
                    Spacer()
                    Button("Remove Capability", role: .destructive) {
                        let id = capability.id
                        model.mutateDraftPackage { draft in
                            draft.capabilities.remove(at: index)
                            for skillIndex in draft.skills.indices {
                                draft.skills[skillIndex].requirements.capabilities.removeAll { $0 == id }
                            }
                        }
                    }
                }
            }
            .padding(.top, 9)
        } label: {
            HStack {
                Image(systemName: "lock.shield")
                Text(capability.title).font(.callout.weight(.semibold))
                Text(capability.id.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(capability.effect.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private var permissionEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Permission requirements").font(.caption.weight(.semibold))
                Spacer()
                Button("Add") {
                    mutate { $0.permissions.append(.init(
                        kind: .accessibility,
                        reason: "Explain why this capability needs access.")) }
                }
            }
            ForEach(Array(capability.permissions.enumerated()), id: \.offset) { permissionIndex, requirement in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("Kind", selection: Binding(
                            get: { requirement.kind },
                            set: { value in mutate { $0.permissions[permissionIndex].kind = value } })) {
                            ForEach(PermissionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        TextField("Target (optional)", text: Binding(
                            get: { requirement.target ?? "" },
                            set: { value in
                                mutate { $0.permissions[permissionIndex].target = value.isEmpty ? nil : value }
                            }))
                            .textFieldStyle(.roundedBorder)
                        Button {
                            mutate { $0.permissions.remove(at: permissionIndex) }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                    TextField("Reason", text: Binding(
                        get: { requirement.reason },
                        set: { value in mutate { $0.permissions[permissionIndex].reason = value } }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            AbilityStudioSchemaPath(path("permissions"))
        }
    }

    private var constraintEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Enforced constraints").font(.caption.weight(.semibold))
                Spacer()
                Button("Add") {
                    mutate { $0.constraints.append(.init(kind: .requiresStage, value: "true")) }
                }
            }
            ForEach(Array(capability.constraints.enumerated()), id: \.offset) { constraintIndex, constraint in
                HStack {
                    Picker("Kind", selection: Binding(
                        get: { constraint.kind },
                        set: { value in mutate { $0.constraints[constraintIndex].kind = value } })) {
                        ForEach(CapabilityConstraint.Kind.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    TextField("Value", text: Binding(
                        get: { constraint.value },
                        set: { value in mutate { $0.constraints[constraintIndex].value = value } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Button {
                        mutate { $0.constraints.remove(at: constraintIndex) }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                }
            }
            AbilityStudioSchemaPath(path("constraints"))
        }
    }

    private func valueTypePicker(
        _ title: String,
        selection: ValueTypeID?,
        onChange: @escaping (inout CapabilitySchema, ValueTypeID?) -> Void
    ) -> some View {
        Picker(title, selection: Binding(
            get: { selection },
            set: { value in mutate { onChange(&$0, value) } })) {
            Text("None").tag(Optional<ValueTypeID>.none)
            ForEach(package.valueTypes, id: \.id) {
                Text($0.title).tag(Optional($0.id))
            }
            if let selection, !package.valueTypes.contains(where: { $0.id == selection }) {
                Text(selection.rawValue).tag(Optional(selection))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func rename(_ value: String) {
        model.mutateDraftPackage { draft in
            guard draft.capabilities.indices.contains(index) else { return }
            let previous = draft.capabilities[index].id
            let next = CapabilityID(value)
            draft.capabilities[index].id = next
            for skillIndex in draft.skills.indices {
                draft.skills[skillIndex].requirements.capabilities =
                    draft.skills[skillIndex].requirements.capabilities.map { $0 == previous ? next : $0 }
            }
        }
    }

    private func mutate(_ change: (inout CapabilitySchema) -> Void) {
        model.mutateDraftPackage { draft in
            guard draft.capabilities.indices.contains(index) else { return }
            change(&draft.capabilities[index])
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<CapabilitySchema, String>) -> Binding<String> {
        Binding(get: { capability[keyPath: keyPath] }, set: { value in mutate { $0[keyPath: keyPath] = value } })
    }

    private func path(_ tail: String) -> String { "capabilities[\(index)].\(tail)" }
}

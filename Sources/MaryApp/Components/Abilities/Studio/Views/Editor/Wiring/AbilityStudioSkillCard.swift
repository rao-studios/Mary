import MaryBrain
import SwiftUI

// MARK: - Skill card

@MainActor
struct AbilityStudioSkillCard: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    let skillIndex: Int
    let onRemove: () -> Void

    private var skill: SkillSchema { package.skills[skillIndex] }
    private var hasPinnedInstalledContract: Bool {
        AbilityStudioEditorIntegrity.hasExternalInstalledFacultyContract(
            skill,
            in: package,
            snapshot: model.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(skill.title).font(.headline)
                Spacer()
                if !hasPinnedInstalledContract {
                    Button("Remove Skill", role: .destructive, action: onRemove)
                }
            }
            if hasPinnedInstalledContract {
                Label(
                    "Installed faculty contract pinned — Mary imported the complete validated callable shape and visual edits cannot weaken it.",
                    systemImage: "lock.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if skill.kind == .workflow {
                Label(
                    "Workflow execution and steps are preserved. Edit this Skill in Advanced Schema until the visual workflow editor is available.",
                    systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            AbilityStudioBlockCard(number: 1, title: "Semantic contract", symbol: "bolt") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if hasPinnedInstalledContract {
                        LabeledContent("Skill id") {
                            Text(skill.id.rawValue).font(.body.monospaced())
                        }
                    } else {
                        AbilityStudioTextField(
                            "Skill id",
                            path: path("id"),
                            text: Binding(
                                get: { skill.id.rawValue },
                                set: { value in rename(value) }),
                            monospaced: true)
                    }
                    AbilityStudioTextField(
                        "Title",
                        path: path("title"),
                        text: stringBinding(\.title))
                }
                AbilityStudioTextArea(
                    "Summary",
                    path: path("summary"),
                    text: stringBinding(\.summary))
                HStack {
                    if hasPinnedInstalledContract || skill.kind == .workflow {
                        LabeledContent("Kind") {
                            Text(skill.kind.rawValue).font(.body.monospaced())
                        }
                    } else {
                        Picker("Kind", selection: Binding(
                            get: { skill.kind },
                            set: { kind in
                                model.mutateValidatedEditorPackage {
                                    try AbilityStudioEditorIntegrity.transitionSkillKind(
                                        in: &$0,
                                        skillID: skill.id,
                                        to: kind)
                                }
                            })) {
                            ForEach(
                                AbilityStudioEditorIntegrity.visuallyAuthorableKinds(
                                    for: skill),
                                id: \.self
                            ) { kind in
                                Text(kind.rawValue)
                                    .tag(kind)
                                    .disabled(!AbilityStudioEditorIntegrity
                                        .canTransitionSkillKind(
                                            in: package,
                                            skillID: skill.id,
                                            to: kind))
                            }
                        }
                    }
                    if hasPinnedInstalledContract {
                        LabeledContent("Access") {
                            Text(skill.access.rawValue).font(.body.monospaced())
                        }
                        LabeledContent("Owns stage") {
                            Text(skill.usesStage ? "Yes" : "No")
                        }
                    } else {
                        Picker("Access", selection: Binding(
                            get: { skill.access },
                            set: { value in mutate { $0.access = value } })) {
                            ForEach(SkillAccess.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        Toggle("Owns stage", isOn: Binding(
                            get: { skill.usesStage },
                            set: { value in mutate { $0.usesStage = value } }))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if hasPinnedInstalledContract {
                        LabeledContent("Timeout") {
                            Text(skill.timeoutSeconds.map { String($0) } ?? "None")
                                .font(.body.monospaced())
                        }
                    } else {
                        AbilityStudioTextField(
                            "Timeout seconds (optional)",
                            path: path("timeoutSeconds"),
                            text: Binding(
                                get: { skill.timeoutSeconds.map { String($0) } ?? "" },
                                set: { value in mutate { $0.timeoutSeconds = Double(value) } }),
                            monospaced: true)
                    }
                    if skill.kind == .effectful {
                        if hasPinnedInstalledContract {
                            LabeledContent("Realization") {
                                Text("Installed compiled faculty")
                            }
                        } else {
                            Picker("Realization", selection: Binding(
                                get: { skill.execution.realizationPolicy },
                                set: { value in mutate { $0.execution.realizationPolicy = value } })) {
                                Text("Authored bindings").tag(SkillExecutionSchema.RealizationPolicy.authoredBindings)
                                Text("Package providers").tag(SkillExecutionSchema.RealizationPolicy.pluginRealizations)
                            }
                        }
                    }
                }
            }

            AbilityStudioBlockCard(number: 2, title: "Ports and requirements", symbol: "arrow.left.arrow.right") {
                if hasPinnedInstalledContract {
                    pinnedPortsAndRequirements
                } else {
                    portEditor(title: "Inputs", ports: skill.inputs, isInput: true)
                    portEditor(title: "Outputs", ports: skill.outputs, isInput: false)
                    AbilityStudioTagEditor(
                        title: "Required capabilities",
                        path: path("requirements.capabilities"),
                        values: skill.requirements.capabilities.map(\.rawValue)) { values in
                        mutate { $0.requirements.capabilities = values.map(CapabilityID.init) }
                    }
                    AbilityStudioTagEditor(
                        title: "Required interactions",
                        path: path("requirements.interactions"),
                        values: skill.requirements.interactions.map(\.rawValue)) { values in
                        mutate { $0.requirements.interactions = values.map(InteractionID.init) }
                    }
                    AbilityStudioTagEditor(
                        title: "Required perceptions",
                        path: path("requirements.perceptions"),
                        values: skill.requirements.perceptions.map(\.rawValue)) { values in
                        mutate { $0.requirements.perceptions = values.map(PerceptionID.init) }
                    }
                    AbilityStudioTagEditor(
                        title: "Supporting Abilities",
                        path: path("requirements.supportingAbilities"),
                        values: skill.requirements.supportingAbilities.map(\.rawValue)) { values in
                        mutate { $0.requirements.supportingAbilities = values.map(AbilityID.init) }
                    }
                }
            }

            if skill.execution.kind == .binding {
                AbilityStudioBlockCard(number: 3, title: "Installed faculty bindings", symbol: "cpu") {
                    installedBindings
                }
            }

            AbilityStudioBlockCard(number: 4, title: "Model projection", symbol: "text.badge.checkmark") {
                if hasPinnedInstalledContract {
                    pinnedModelProjection
                } else {
                    Toggle("Callable by the model", isOn: Binding(
                        get: { skill.modelExposure.enabled },
                        set: { value in mutate { $0.modelExposure.enabled = value } }))
                    AbilityStudioTextField(
                        "Invocation name",
                        path: path("modelExposure.invocationName"),
                        text: Binding(
                            get: { skill.modelExposure.invocationName ?? "" },
                            set: { value in
                                mutate { $0.modelExposure.invocationName = value.isEmpty ? nil : value }
                            }),
                        monospaced: true)
                    Toggle("Inherit installed binding contract", isOn: Binding(
                        get: { skill.modelExposure.inheritsBindingContract },
                        set: { value in mutate { $0.modelExposure.inheritsBindingContract = value } }))
                    parameterEditor
                }
            }

            AbilityStudioBlockCard(number: 5, title: "Artifact semantics", symbol: "square.on.square") {
                if hasPinnedInstalledContract {
                    pinnedArtifactSemantics
                } else {
                    AbilityStudioSkillSemanticsEditor(
                        model: model,
                        package: package,
                        skill: skill)
                }
            }

            AbilityStudioBlockCard(number: 6, title: "Skill routing", symbol: "arrow.triangle.branch") {
                AbilityStudioRoutingPolicyEditor(policy: skill.routing, path: path("routing")) { value in
                    mutate { $0.routing = value }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(skill.kind == .workflow)
    }

    private var pinnedPortsAndRequirements: some View {
        VStack(alignment: .leading, spacing: 10) {
            pinnedPorts("Inputs", skill.inputs)
            pinnedPorts("Outputs", skill.outputs)
            pinnedContractValues(
                "Required capabilities",
                skill.requirements.capabilities.map(\.rawValue))
            pinnedContractValues(
                "Required interactions",
                skill.requirements.interactions.map(\.rawValue))
            pinnedContractValues(
                "Required perceptions",
                skill.requirements.perceptions.map(\.rawValue))
            pinnedContractValues(
                "Optional interactions",
                skill.requirements.optionalInteractions.map(\.rawValue))
            pinnedContractValues(
                "Optional perceptions",
                skill.requirements.optionalPerceptions.map(\.rawValue))
            pinnedContractValues(
                "Supporting Abilities",
                skill.requirements.supportingAbilities.map(\.rawValue))
        }
    }

    private func pinnedPorts(
        _ title: String,
        _ ports: [SkillPortSchema]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            if ports.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(ports, id: \.name) { port in
                    HStack {
                        Text(port.name).font(.caption.monospaced())
                        Text("→ \(port.valueType.rawValue)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(port.required ? "required" : "optional")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pinnedContractValues(
        _ title: String,
        _ values: [String]
    ) -> some View {
        LabeledContent(title) {
            Text(values.isEmpty ? "None" : values.joined(separator: ", "))
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private var pinnedArtifactSemantics: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("Artifact role") {
                Text(skill.semantics?.artifactRole.rawValue ?? "Unspecified")
                    .font(.body.monospaced())
            }
            if let reference = skill.semantics?.producesReference {
                LabeledContent("Produces reference") {
                    Text(reference.rawValue).font(.body.monospaced())
                }
            }
            if let targets = skill.semantics?.targetParameters, !targets.isEmpty {
                LabeledContent("Target parameters") {
                    Text(targets.joined(separator: ", "))
                        .font(.body.monospaced())
                }
            }
        }
    }

    private var pinnedModelProjection: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("Callable by the model") {
                Text(skill.modelExposure.enabled ? "Yes" : "No")
            }
            LabeledContent("Invocation name") {
                Text(skill.modelExposure.invocationName ?? "Inherited")
                    .font(.body.monospaced())
            }
            LabeledContent("Inherits binding contract") {
                Text(skill.modelExposure.inheritsBindingContract ? "Yes" : "No")
            }
            Text("Parameters").font(.caption.weight(.semibold))
            if skill.modelExposure.parameters.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(skill.modelExposure.parameters, id: \.name) { parameter in
                    HStack {
                        Text(parameter.name).font(.caption.monospaced())
                        Text(parameter.type).font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(parameter.required ? "required" : "optional")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func portEditor(title: String, ports: [SkillPortSchema], isInput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Button("Add") {
                    mutate {
                        let existing = (isInput ? $0.inputs : $0.outputs).map(\.name)
                        let name = abilityStudioFirstUnusedName(
                            stem: isInput ? "input" : "output",
                            separator: "_",
                            existing: existing)
                        let port = SkillPortSchema(
                            name: name,
                            valueType: ValueTypeID(package.valueTypes.first?.id.rawValue
                                                   ?? "\(package.package.id.rawValue).value"),
                            summary: "Describe this typed port.")
                        if isInput { $0.inputs.append(port) } else { $0.outputs.append(port) }
                    }
                }
            }
            ForEach(Array(ports.enumerated()), id: \.offset) { index, port in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("name", text: Binding(
                        get: { port.name },
                        set: { value in mutatePort(index, isInput: isInput) { $0.name = value } }))
                        .textFieldStyle(.roundedBorder)
                    Picker("Type", selection: Binding(
                        get: { port.valueType },
                        set: { value in mutatePort(index, isInput: isInput) { $0.valueType = value } })) {
                        ForEach(package.valueTypes, id: \.id) { Text($0.title).tag($0.id) }
                        if !package.valueTypes.contains(where: { $0.id == port.valueType }) {
                            Text(port.valueType.rawValue).tag(port.valueType)
                        }
                    }
                    Toggle("Required", isOn: Binding(
                        get: { port.required },
                        set: { value in mutatePort(index, isInput: isInput) { $0.required = value } }))
                    Button {
                        mutate {
                            if isInput { $0.inputs.remove(at: index) }
                            else { $0.outputs.remove(at: index) }
                        }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                }
                TextField("Summary", text: Binding(
                    get: { port.summary },
                    set: { value in mutatePort(index, isInput: isInput) { $0.summary = value } }))
                    .textFieldStyle(.roundedBorder)
            }
            AbilityStudioSchemaPath(path(isInput ? "inputs" : "outputs"))
        }
        .padding(9)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var installedBindings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("An installed-faculty Ability selects an operation already published by Mary. The package names the contract; it does not import implementation code.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(skill.execution.bindings.enumerated()), id: \.offset) { index, binding in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(binding.adapterID.rawValue, systemImage: "cpu")
                            .font(.caption.monospaced())
                        Text("/")
                        Text(binding.operation).font(.caption.monospaced())
                        Spacer()
                        if hasPinnedInstalledContract {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                mutate { $0.execution.bindings.remove(at: index) }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                    if hasPinnedInstalledContract {
                        LabeledContent("Preference") {
                            Text(String(binding.preference)).font(.body.monospaced())
                        }
                        LabeledContent("Target classes") {
                            Text(binding.targetClasses.joined(separator: ", "))
                                .font(.body.monospaced())
                        }
                    } else {
                        HStack {
                            AbilityStudioIntegerField(
                                "Preference",
                                path: path("execution.bindings[\(index)].preference"),
                                value: binding.preference) { value in
                                mutate { $0.execution.bindings[index].preference = value }
                            }
                            AbilityStudioTagEditor(
                                title: "Target classes",
                                path: path("execution.bindings[\(index)].targetClasses"),
                                values: binding.targetClasses) { values in
                                mutate { $0.execution.bindings[index].targetClasses = values }
                            }
                        }
                    }
                }
                .padding(9)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Menu(hasPinnedInstalledContract
                 ? "Replace Installed Faculty Contract"
                 : "Adopt Installed Faculty Contract") {
                ForEach(installedFacultyOptions) { option in
                    Button("\(option.manifest.title) · \(option.operation.operation)") {
                        model.mutateValidatedEditorPackage {
                            try AbilityStudioEditorIntegrity.adoptInstalledFaculty(
                                option,
                                for: skill.id,
                                in: &$0)
                        }
                    }
                    .disabled(!option.operation.isAvailable)
                }
            }
        }
    }

    private var installedFacultyOptions: [AbilityStudioInstalledFacultyOption] {
        AbilityStudioAuthoringCatalog.installedFaculties(in: model.snapshot)
    }

    private var parameterEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Parameters").font(.caption.weight(.semibold))
                Spacer()
                Button("Add") {
                    mutate {
                        let name = abilityStudioFirstUnusedName(
                            stem: "parameter",
                            separator: "_",
                            existing: $0.modelExposure.parameters.map(\.name))
                        $0.modelExposure.parameters.append(.init(
                            name: name,
                            type: "string",
                            summary: "Describe this parameter.",
                            required: true))
                    }
                }
            }
            ForEach(Array(skill.modelExposure.parameters.enumerated()), id: \.offset) { index, parameter in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("name", text: Binding(
                            get: { parameter.name },
                            set: { value in mutate { $0.modelExposure.parameters[index].name = value } }))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                        Picker("Type", selection: Binding(
                            get: { parameter.type },
                            set: { value in mutate { $0.modelExposure.parameters[index].type = value } })) {
                            ForEach(["string", "boolean", "integer", "number", "object", "array"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        Toggle("Required", isOn: Binding(
                            get: { parameter.required },
                            set: { value in mutate { $0.modelExposure.parameters[index].required = value } }))
                        Button {
                            mutate { $0.modelExposure.parameters.remove(at: index) }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                    TextField("Summary", text: Binding(
                        get: { parameter.summary },
                        set: { value in mutate { $0.modelExposure.parameters[index].summary = value } }))
                        .textFieldStyle(.roundedBorder)
                    AbilityStudioTagEditor(
                        title: "Enum values",
                        path: path("modelExposure.parameters[\(index)].enumValues"),
                        values: parameter.enumValues) { values in
                        mutate { $0.modelExposure.parameters[index].enumValues = values }
                    }
                }
                .padding(9)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func mutatePort(
        _ index: Int,
        isInput: Bool,
        change: (inout SkillPortSchema) -> Void
    ) {
        mutate {
            if isInput { change(&$0.inputs[index]) }
            else { change(&$0.outputs[index]) }
        }
    }

    private func rename(_ value: String) {
        let current = skill.id
        model.mutateAuthoringDocument {
            try $0.updateSkill(current) { skill in
                skill.id = SkillID(value)
            }
        }
    }

    private func mutate(_ change: (inout SkillSchema) -> Void) {
        model.mutateDraftPackage { draft in
            guard draft.skills.indices.contains(skillIndex) else { return }
            change(&draft.skills[skillIndex])
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<SkillSchema, String>) -> Binding<String> {
        Binding(
            get: { skill[keyPath: keyPath] },
            set: { value in mutate { $0[keyPath: keyPath] = value } })
    }

    private func path(_ tail: String) -> String { "skills[\(skillIndex)].\(tail)" }
}

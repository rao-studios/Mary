import MaryBrain
import SwiftUI

// MARK: - Value type card

@MainActor
struct AbilityStudioValueTypeCard: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    let valueType: ValueTypeSchema
    let index: Int

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    AbilityStudioTextField(
                        "Value id",
                        path: path("id"),
                        text: Binding(
                            get: { valueType.id.rawValue },
                            set: { value in rename(value) }),
                        monospaced: true)
                    Picker("Shape", selection: Binding(
                        get: { valueType.shape },
                        set: { shape in
                            mutate {
                                $0.shape = shape
                                if shape != .object { $0.fields = [] }
                                if shape != .array { $0.itemType = nil }
                                if shape != .enumeration { $0.enumValues = [] }
                            }
                        })) {
                        ForEach(ValueShape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                AbilityStudioTextField("Title", path: path("title"), text: stringBinding(\.title))
                AbilityStudioTextArea("Summary", path: path("summary"), text: stringBinding(\.summary))
                shapeEditor
                HStack {
                    Spacer()
                    Button("Remove Value Type", role: .destructive) { remove() }
                }
            }
            .padding(.top, 9)
        } label: {
            HStack {
                Image(systemName: "cube.transparent")
                Text(valueType.title).font(.callout.weight(.semibold))
                Text(valueType.id.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(valueType.shape.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var shapeEditor: some View {
        switch valueType.shape {
        case .enumeration:
            AbilityStudioTagEditor(
                title: "Allowed values",
                path: path("enumValues"),
                values: valueType.enumValues) { values in mutate { $0.enumValues = values } }
        case .array:
            Picker("Item type", selection: Binding(
                get: { valueType.itemType },
                set: { value in mutate { $0.itemType = value } })) {
                Text("Choose…").tag(Optional<ValueTypeID>.none)
                ForEach(package.valueTypes.filter { $0.id != valueType.id }, id: \.id) {
                    Text($0.title).tag(Optional($0.id))
                }
            }
        case .object:
            fieldEditor
        default:
            Text("This scalar shape has no additional fields.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fieldEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Object fields").font(.caption.weight(.semibold))
                Spacer()
                Button("Add") {
                    mutate {
                        let name = abilityStudioFirstUnusedName(
                            stem: "field",
                            separator: "_",
                            existing: $0.fields.map(\.name))
                        $0.fields.append(.init(
                            name: name,
                            valueType: package.valueTypes.first(where: { $0.id != valueType.id })?.id
                                ?? ValueTypeID("\(package.package.id.rawValue).text"),
                            summary: "Describe this field."))
                    }
                }
            }
            ForEach(Array(valueType.fields.enumerated()), id: \.offset) { fieldIndex, field in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("name", text: Binding(
                            get: { field.name },
                            set: { value in mutate { $0.fields[fieldIndex].name = value } }))
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                        Picker("Type", selection: Binding(
                            get: { field.valueType },
                            set: { value in mutate { $0.fields[fieldIndex].valueType = value } })) {
                            ForEach(package.valueTypes.filter { $0.id != valueType.id }, id: \.id) {
                                Text($0.title).tag($0.id)
                            }
                            if !package.valueTypes.contains(where: { $0.id == field.valueType }) {
                                Text(field.valueType.rawValue).tag(field.valueType)
                            }
                        }
                        Picker("Privacy", selection: Binding(
                            get: { field.privacy },
                            set: { value in mutate { $0.fields[fieldIndex].privacy = value } })) {
                            ForEach(DataPrivacyClass.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Required", isOn: Binding(
                            get: { field.required },
                            set: { value in mutate { $0.fields[fieldIndex].required = value } }))
                        Button {
                            mutate { $0.fields.remove(at: fieldIndex) }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                    TextField("Summary", text: Binding(
                        get: { field.summary },
                        set: { value in mutate { $0.fields[fieldIndex].summary = value } }))
                        .textFieldStyle(.roundedBorder)
                }
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            }
            AbilityStudioSchemaPath(path("fields"))
        }
    }

    private func rename(_ value: String) {
        model.mutateDraftPackage { draft in
            guard draft.valueTypes.indices.contains(index) else { return }
            let previous = draft.valueTypes[index].id
            let next = ValueTypeID(value)
            draft.valueTypes[index].id = next
            for skillIndex in draft.skills.indices {
                for portIndex in draft.skills[skillIndex].inputs.indices
                where draft.skills[skillIndex].inputs[portIndex].valueType == previous {
                    draft.skills[skillIndex].inputs[portIndex].valueType = next
                }
                for portIndex in draft.skills[skillIndex].outputs.indices
                where draft.skills[skillIndex].outputs[portIndex].valueType == previous {
                    draft.skills[skillIndex].outputs[portIndex].valueType = next
                }
            }
            for capabilityIndex in draft.capabilities.indices {
                if draft.capabilities[capabilityIndex].inputType == previous {
                    draft.capabilities[capabilityIndex].inputType = next
                }
                if draft.capabilities[capabilityIndex].outputType == previous {
                    draft.capabilities[capabilityIndex].outputType = next
                }
            }
            for typeIndex in draft.valueTypes.indices {
                if draft.valueTypes[typeIndex].itemType == previous {
                    draft.valueTypes[typeIndex].itemType = next
                }
                for fieldIndex in draft.valueTypes[typeIndex].fields.indices
                where draft.valueTypes[typeIndex].fields[fieldIndex].valueType == previous {
                    draft.valueTypes[typeIndex].fields[fieldIndex].valueType = next
                }
            }
        }
    }

    private func remove() {
        let id = valueType.id
        model.mutateDraftPackage { draft in
            draft.valueTypes.remove(at: index)
            // Do not guess replacements. Validation points every remaining
            // reference at the exact visual card that needs attention.
            _ = id
        }
    }

    private func mutate(_ change: (inout ValueTypeSchema) -> Void) {
        model.mutateDraftPackage { draft in
            guard draft.valueTypes.indices.contains(index) else { return }
            change(&draft.valueTypes[index])
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<ValueTypeSchema, String>) -> Binding<String> {
        Binding(get: { valueType[keyPath: keyPath] }, set: { value in mutate { $0[keyPath: keyPath] = value } })
    }

    private func path(_ tail: String) -> String { "valueTypes[\(index)].\(tail)" }
}

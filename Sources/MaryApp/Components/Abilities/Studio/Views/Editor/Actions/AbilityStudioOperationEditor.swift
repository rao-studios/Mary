import MaryBrain
import SwiftUI

// MARK: - Operation and input cards

@MainActor
struct AbilityStudioOperationEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let plugin: PluginSchema
    let operationIndex: Int
    let onRemove: () -> Void

    private var operation: PluginOperationSchema { plugin.operations[operationIndex] }
    private var authorableInputKinds: [PluginOperationInputKind] {
        [.text, .number, .integer]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(operation.title).font(.headline)
                    Text(operation.operation).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove Action", role: .destructive, action: onRemove)
            }

            AbilityStudioBlockCard(number: 1, title: "Action contract", symbol: "signature") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    AbilityStudioTextField(
                        "Operation name",
                        path: path("operation"),
                        text: Binding(
                            get: { operation.operation },
                            set: { name in
                                model.mutateValidatedEditorPackage {
                                    try AbilityStudioEditorIntegrity.renamePluginOperation(
                                        in: &$0,
                                        from: operation.operation,
                                        to: name)
                                }
                            }
                        ),
                        monospaced: true)
                    AbilityStudioTextField(
                        "Title",
                        path: path("title"),
                        text: operationBinding(\.title))
                }
                AbilityStudioTextArea(
                    "Summary",
                    path: path("summary"),
                    text: operationBinding(\.summary))
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    AbilityStudioDoubleField(
                        "Timeout seconds",
                        path: path("timeoutSeconds"),
                        value: operation.timeoutSeconds,
                        range: 0.25...PluginValidator.maximumOperationSeconds) { value in
                        mutate { $0.timeoutSeconds = value }
                    }
                    if plugin.adapters.count > 1 {
                        Picker("Adapter", selection: Binding(
                            get: { operation.adapterID },
                            set: { value in mutate { $0.adapterID = value } })) {
                            Text("Choose…").tag(Optional<AdapterID>.none)
                            ForEach(plugin.adapters, id: \.id) {
                                Text($0.title).tag(Optional($0.id))
                            }
                        }
                    }
                }
                HStack {
                    Label("applicationFrontmost", systemImage: "checkmark.circle")
                    Label("applicationWindowAvailable", systemImage: "checkmark.circle")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.green)
                AbilityStudioSchemaPath(path("postconditions"))
            }

            AbilityStudioBlockCard(number: 2, title: "Semantic role", symbol: "point.3.connected.trianglepath.dotted") {
                AbilityStudioOperationSemanticsEditor(
                    model: model,
                    operation: operation)
                    .id(operation.operation)
            }

            AbilityStudioBlockCard(number: 3, title: "Recipe inputs", symbol: "slider.horizontal.3") {
                Text("Declare normalized values once, then bind them to pointer coordinates or other typed recipe blocks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(operation.inputs, id: \.name) { input in
                    if let index = operation.inputs.firstIndex(where: {
                        $0.name == input.name
                    }) {
                        inputCard(input, index: index)
                    }
                }
                Menu("Add Input") {
                    ForEach(authorableInputKinds, id: \.self) { kind in
                        Button(kind.studioTitle) { addInput(kind) }
                    }
                }
                Text("Add the matching recipe block first. Studio connects the new input to its first fixed text, coordinate, or scroll expression and preserves that literal as a fallback.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            AbilityStudioBlockCard(number: 4, title: "Recipe blocks", symbol: "square.stack.3d.up") {
                AbilityStudioRecipeSequencer(
                    model: model,
                    operation: operation,
                    operationIndex: operationIndex)
            }
            AbilityStudioBlockCard(number: 5, title: "Cleanup blocks", symbol: "arrow.uturn.backward.circle") {
                Text("Optional best-effort steps release a temporary tool before Mary restores the user's original application, focused surface, and pointer. Cleanup is deliberately limited to a key chord or bounded wait.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AbilityStudioRecipeSequencer(
                    model: model,
                    operation: operation,
                    operationIndex: operationIndex,
                    lane: .cleanup)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputCard(_ input: PluginOperationInputSchema, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Input \(index + 1)").font(.caption.weight(.semibold))
                Spacer()
                Button("Remove") {
                    model.mutateValidatedEditorPackage {
                        try AbilityStudioEditorIntegrity.removePluginInput(
                            input.name,
                            from: operation.operation,
                            in: &$0)
                    }
                }
                    .buttonStyle(.link)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                AbilityStudioTextField(
                    "Name",
                    path: path("inputs[\(index)].name"),
                    text: Binding(
                        get: { input.name },
                        set: { value in
                            model.mutateValidatedEditorPackage {
                                try AbilityStudioEditorIntegrity.renamePluginInput(
                                    in: &$0,
                                    operation: operation.operation,
                                    from: input.name,
                                    to: value)
                            }
                        }),
                    monospaced: true)
                Picker("Kind", selection: Binding(
                    get: { input.kind },
                    set: { value in
                        mutateInput(input.name) {
                            $0.kind = value
                            $0.minimum = value.isNumeric ? ($0.minimum ?? 0) : nil
                            $0.maximum = value.isNumeric ? ($0.maximum ?? 1) : nil
                            $0.enumValues = value == .text ? $0.enumValues : []
                            $0.defaultValue = $0.required
                                ? nil : value.studioFallback
                        }
                    })) {
                    ForEach(
                        input.kind == .boolean
                            ? authorableInputKinds + [.boolean]
                            : authorableInputKinds,
                        id: \.self
                    ) {
                        Text($0.studioTitle).tag($0)
                    }
                }
                .frame(maxWidth: 150)
                .disabled(input.kind == .boolean)
                Toggle("Required", isOn: Binding(
                    get: { input.required },
                    set: { value in
                        mutateInput(input.name) {
                            $0.required = value
                            $0.defaultValue = value
                                ? nil : ($0.defaultValue ?? $0.kind.studioFallback)
                        }
                    }))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if input.kind.isNumeric {
                    optionalDoubleField("Minimum", value: input.minimum) { value in
                        mutateInput(input.name) { $0.minimum = value }
                    }
                    optionalDoubleField("Maximum", value: input.maximum) { value in
                        mutateInput(input.name) { $0.maximum = value }
                    }
                }
                if !input.required {
                    fallbackEditor(input, index: index)
                }
            }
            if input.kind == .text {
                AbilityStudioTagEditor(
                    title: "Allowed values (optional)",
                    path: path("inputs[\(index)].enumValues"),
                    values: input.enumValues) { values in
                    mutateInput(input.name) { $0.enumValues = values }
                }
            } else if input.kind == .boolean {
                Label(
                    "Boolean inputs remain schema-visible but are not visually authorable until the closed recipe vocabulary gains a boolean consumer.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func optionalDoubleField(
        _ title: String,
        value: Double?,
        onChange: @escaping (Double?) -> Void
    ) -> some View {
        AbilityStudioTextField(
            title,
            path: path("inputs"),
            text: Binding(
                get: { value.map { String($0) } ?? "" },
                set: { text in
                    onChange(Double(text))
                }),
            monospaced: true)
    }

    @ViewBuilder
    private func fallbackEditor(
        _ input: PluginOperationInputSchema,
        index: Int
    ) -> some View {
        if input.kind == .boolean {
            Picker("Fallback", selection: Binding(
                get: { input.defaultValue ?? "false" },
                set: { value in
                    mutateInput(input.name) { $0.defaultValue = value }
                })) {
                    Text("False").tag("false")
                    Text("True").tag("true")
                }
        } else {
            AbilityStudioTextField(
                "Fallback",
                path: path("inputs[\(index)].defaultValue"),
                text: Binding(
                    get: { input.defaultValue ?? input.kind.studioFallback },
                    set: { value in
                        mutateInput(input.name) {
                            $0.defaultValue = value.isEmpty ? nil : value
                        }
                    }),
                monospaced: true)
        }
    }

    private func addInput(_ kind: PluginOperationInputKind) {
        let name = abilityStudioFirstUnusedName(
            stem: kind.studioInputStem,
            separator: "_",
            existing: operation.inputs.map(\.name))
        let bounds = nextNumericInputBounds
        model.mutateValidatedEditorPackage {
            try AbilityStudioEditorIntegrity.addPluginInput(
                .init(
                    name: name,
                    kind: kind,
                    minimum: kind.isNumeric ? bounds.lowerBound : nil,
                    maximum: kind.isNumeric ? bounds.upperBound : nil),
                to: operation.operation,
                in: &$0)
        }
    }

    private var nextNumericInputBounds: ClosedRange<Double> {
        for step in operation.steps {
            if step.point?.x.value != nil || step.point?.y.value != nil
                || step.rect?.x.value != nil || step.rect?.y.value != nil {
                return 0...1
            }
            if step.rect?.width.value != nil || step.rect?.height.value != nil {
                return 0.001...1
            }
            if step.deltaX?.value != nil || step.deltaY?.value != nil {
                return -10_000...10_000
            }
        }
        return 0...1
    }

    private func mutate(_ change: (inout PluginOperationSchema) -> Void) {
        model.mutateValidatedEditorPackage {
            try AbilityStudioEditorIntegrity.updatePluginOperation(
                in: &$0,
                operation: operation.operation,
                change)
        }
    }

    private func mutateInput(
        _ name: String,
        _ change: @escaping (inout PluginOperationInputSchema) -> Void
    ) {
        mutate { operation in
            guard let index = operation.inputs.firstIndex(where: {
                $0.name == name
            }) else { return }
            change(&operation.inputs[index])
        }
    }

    private func operationBinding(_ keyPath: WritableKeyPath<PluginOperationSchema, String>) -> Binding<String> {
        Binding(
            get: { operation[keyPath: keyPath] },
            set: { value in mutate { $0[keyPath: keyPath] = value } })
    }

    private func path(_ tail: String) -> String {
        "plugin.operations[\(operationIndex)].\(tail)"
    }
}

private extension PluginOperationInputKind {
    var isNumeric: Bool { self == .number || self == .integer }

    var studioTitle: String {
        switch self {
        case .text: return "Text"
        case .number: return "Number"
        case .integer: return "Integer"
        case .boolean: return "Boolean"
        }
    }

    var studioInputStem: String {
        switch self {
        case .text: return "text"
        case .number: return "value"
        case .integer: return "count"
        case .boolean: return "choice"
        }
    }

    var studioFallback: String {
        switch self {
        case .text: return "Text"
        case .number: return "0.5"
        case .integer: return "0"
        case .boolean: return "false"
        }
    }
}

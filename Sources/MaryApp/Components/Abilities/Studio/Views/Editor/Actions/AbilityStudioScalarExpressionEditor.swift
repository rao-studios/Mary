import MaryBrain
import SwiftUI

struct AbilityStudioScalarExpressionEditor: View {
    let label: String
    let path: String
    let expression: PluginScalarExpression
    let inputNames: [String]
    let valueRange: ClosedRange<Double>
    let valueLabel: String
    let fixedDefault: Double
    let onChange: (PluginScalarExpression) -> Void

    private var usesInput: Bool { expression.input != nil }

    init(
        label: String,
        path: String,
        expression: PluginScalarExpression,
        inputNames: [String],
        valueRange: ClosedRange<Double> = 0...1,
        valueLabel: String = "Normalized value",
        fixedDefault: Double = 0.5,
        onChange: @escaping (PluginScalarExpression) -> Void
    ) {
        self.label = label
        self.path = path
        self.expression = expression
        self.inputNames = inputNames
        self.valueRange = valueRange
        self.valueLabel = valueLabel
        self.fixedDefault = fixedDefault
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.caption.weight(.medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { usesInput },
                    set: { input in
                        onChange(input
                                 ? .init(input: inputNames.first ?? "")
                                 : .init(value: bounded(
                                    expression.value
                                        ?? expression.defaultValue
                                        ?? fixedDefault)))
                    })) {
                    Text("Fixed").tag(false)
                    Text("Input").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 115)
                .disabled(inputNames.isEmpty && !usesInput)
            }
            if usesInput {
                Picker("Input", selection: Binding(
                    get: { expression.input ?? inputNames.first ?? "" },
                    set: { onChange(.init(input: $0, defaultValue: expression.defaultValue)) })) {
                    ForEach(inputNames, id: \.self) { Text($0).tag($0) }
                }
                .disabled(inputNames.isEmpty)
                AbilityStudioTextField(
                    "Fallback (optional)",
                    path: "\(path).defaultValue",
                    text: Binding(
                        get: { expression.defaultValue.map { String($0) } ?? "" },
                        set: { value in
                            onChange(.init(
                                input: expression.input ?? inputNames.first ?? "",
                                defaultValue: Double(value)))
                        }),
                    monospaced: true)
            } else {
                AbilityStudioDoubleField(
                    valueLabel,
                    path: path,
                    value: expression.value ?? fixedDefault,
                    range: valueRange) { value in onChange(.init(value: value)) }
            }
            AbilityStudioSchemaPath(path)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func bounded(_ value: Double) -> Double {
        min(max(value, valueRange.lowerBound), valueRange.upperBound)
    }
}

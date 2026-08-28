import MaryBrain
import SwiftUI

struct AbilityStudioReviewEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    private var errors: [SchemaIssue] {
        model.validation.issues.filter { $0.severity == .error }
    }

    private var warnings: [SchemaIssue] {
        model.validation.issues.filter { $0.severity == .warning }
    }

    var body: some View {
        AbilityStudioStageScroll(
            title: "The file is the proof",
            introduction: "Review the exact package graph Mary will activate. Saving writes canonical `.mary` JSON and swaps the registry only after every schema, provider, and safety check succeeds.") {
            AbilityStudioEditorSection("Verdict", symbol: model.validation.isValid ? "checkmark.seal.fill" : "xmark.seal.fill") {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(model.validation.isValid ? Color.green.opacity(0.13) : Color.red.opacity(0.13))
                            .frame(width: 62, height: 62)
                        Image(systemName: model.validation.isValid ? "checkmark" : "xmark")
                            .font(.title.bold())
                            .foregroundStyle(model.validation.isValid ? .green : .red)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.validation.isValid
                             ? (model.isCreatingNewPackage
                                ? "Ready for first save"
                                : "Ready to activate")
                             : "Not ready to save")
                            .font(.title3.weight(.semibold))
                        Text("\(errors.count) errors · \(warnings.count) advisories")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Validate", action: model.validateDraft)
                    Button("Save & Activate", action: model.save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEditSelectedPackage || !model.isDirty || !model.validation.isValid)
                }
            }

            AbilityStudioEditorSection("Pure execution boundary", symbol: "checkmark.shield") {
                Label("No executable source in this package", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Application abilities may bind an installed compiled faculty or describe macUI actions from Mary's closed grammar: key chords, bounded text entry, pointer movement and gestures, scrolling, focused-window rebinds, cleanup, waits, and Mary-verified postconditions.")
                    .foregroundStyle(.secondary)
                Text("They cannot name a language, shell, process, command, executable script, receipt, control-bearing text path, or author-defined output.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            AbilityStudioEditorSection("Package graph", symbol: "square.grid.3x3") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    reviewRow("Paradigm", package.paradigm.label)
                    reviewRow("Skills", String(package.skills.count))
                    reviewRow("Capabilities", String(package.capabilities.count))
                    reviewRow("Value types", String(package.valueTypes.count))
                    reviewRow("Interactions", String(package.interactions.count))
                    reviewRow("Perceptions", String(package.perceptions.count))
                    reviewRow("Callable recipes", String(package.plugin?.operations.count ?? 0))
                    reviewRow("Realizations", String(package.plugin?.realizations.count ?? 0))
                    reviewRow("Dependencies", String(package.dependencies.count))
                }
            }

            AbilityStudioEditorSection("Take it with you", symbol: "square.and.arrow.up") {
                Text("Export produces the current visual draft, even before saving it into this Mary installation. It must still pass the same graph validation.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Export .mary…", action: model.exportPackage)
                        .disabled(!model.validation.isValid)
                }
            }
        }
    }

    @ViewBuilder
    private func reviewRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }
}

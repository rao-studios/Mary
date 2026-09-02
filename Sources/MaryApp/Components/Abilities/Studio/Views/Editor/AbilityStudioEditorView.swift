import AppKit
import MaryBrain
import SwiftUI

// MARK: - Ability Editor shell

/// Visual authoring for a `.mary` package. Same draft string as the Schema tab (`mutateDraftPackage`).
enum AbilityStudioEditorStage: String, CaseIterable, Identifiable {
    case identity
    case intent
    case actions
    // No plans/artifacts stages — those sections are not in Mary's package grammar.
    case wiring
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .identity: return "Identity"
        case .intent: return "Intent"
        case .actions: return "Recipes"
        case .wiring: return "Wiring"
        case .review: return "Review"
        }
    }

    var subtitle: String {
        switch self {
        case .identity: return "What this Ability is"
        case .intent: return "When and why it helps"
        case .actions: return "Callable actions through visible controls"
        case .wiring: return "Skills and contracts"
        case .review: return "Validate and activate"
        }
    }

    var symbol: String {
        switch self {
        case .identity: return "shippingbox"
        case .intent: return "scope"
        case .actions: return "point.3.filled.connected.trianglepath.dotted"
        case .wiring: return "point.3.connected.trianglepath.dotted"
        case .review: return "checkmark.seal"
        }
    }
}

@MainActor
struct AbilityStudioEditorView: View {
    @ObservedObject var model: AbilityStudioViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var stage: AbilityStudioEditorStage = .identity
    @State private var showsSource = false
    @State private var showsWarnings = false
    @State private var showsRevertConfirmation = false

    var body: some View {
        Group {
            if let package = model.draftPackage {
                HSplitView {
                    stageRail(package)
                        .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)

                    VStack(spacing: 0) {
                        editorToolbar(package)
                        Divider()
                        if showsSource {
                            AbilityStudioAdvancedSchemaEditor(model: model)
                        } else {
                            stageView(package)
                        }
                        Divider()
                        statusBar
                    }
                    .frame(minWidth: 620)

                    AbilityStudioEditorIssueInspector(
                        model: model,
                        showsWarnings: $showsWarnings,
                        onNavigate: { destination in
                            showsSource = false
                            stage = destination
                        })
                    .frame(minWidth: 270, idealWidth: 300, maxWidth: 360)
                }
            } else {
                ContentUnavailableView(
                    "This draft cannot be opened visually",
                    systemImage: "curlybraces.square",
                    description: Text("Open Advanced Schema, repair the JSON, and apply it to return to visual editing."))
                .safeAreaInset(edge: .top) {
                    HStack {
                        Spacer()
                        Button("Advanced Schema") { showsSource = true }
                    }
                    .padding()
                    .background(.bar)
                }
                .overlay {
                    if showsSource {
                        AbilityStudioAdvancedSchemaEditor(model: model)
                            .background(.background)
                    }
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .confirmationDialog(
            model.isCreatingNewPackage
                ? "Discard this unsaved Ability?"
                : "Revert all unsaved changes?",
            isPresented: $showsRevertConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                model.isCreatingNewPackage ? "Discard Ability" : "Revert Changes",
                role: .destructive,
                action: revertOrDiscard)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(model.isCreatingNewPackage
                 ? "This closes the editor. No package has been installed or activated."
                 : "The current draft will be replaced by the active package.")
        }
    }

    private func stageRail(_ package: MaryAbilityPackage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Color.maryAbilityTint(package.ability.tint))
                        .frame(width: 12, height: 12)
                    Text(package.ability.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text("\(package.package.id.rawValue).mary")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Label("Pure declarative package", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array(AbilityStudioEditorStage.allCases.enumerated()), id: \.element) { index, item in
                        Button {
                            showsSource = false
                            stage = item
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(stage == item ? Color.accentColor : Color.secondary.opacity(0.14))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: item.symbol)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(stage == item ? .white : .secondary)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(index + 1). \(item.title)")
                                        .font(.callout.weight(.medium))
                                    Text(item.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                let count = issueCount(for: item)
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.red.opacity(0.14), in: Capsule())
                                        .foregroundStyle(.red)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                stage == item && !showsSource
                                    ? Color.accentColor.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }

            Divider()
            Button {
                showsSource.toggle()
            } label: {
                Label(
                    showsSource ? "Return to Visual Editor" : "Advanced Schema",
                    systemImage: showsSource ? "square.grid.2x2" : "curlybraces")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(showsSource ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .background(.regularMaterial)
    }

    private func editorToolbar(_ package: MaryAbilityPackage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showsSource ? "Advanced Schema" : stage.title)
                    .font(.title3.weight(.semibold))
                Text(showsSource
                     ? "The canonical `.mary` source generated by these controls."
                     : stage.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDirty {
                Label("Unsaved", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button(
                model.isCreatingNewPackage ? "Discard Draft" : "Revert",
                action: { showsRevertConfirmation = true })
                .disabled(!model.isDirty)
            Button("Validate", action: model.validateDraft)
            Button(model.isCreatingNewPackage ? "Save & Activate" : "Save", action: model.save)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canEditSelectedPackage || !model.isDirty || !model.validation.isValid)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private func stageView(_ package: MaryAbilityPackage) -> some View {
        switch stage {
        case .identity:
            AbilityStudioIdentityEditor(model: model, package: package)
        case .intent:
            AbilityStudioIntentEditor(model: model, package: package)
        case .actions:
            AbilityStudioActionsEditor(model: model, package: package)
        case .wiring:
            AbilityStudioWiringEditor(model: model, package: package)
        case .review:
            AbilityStudioReviewEditor(model: model, package: package)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.validation.isValid {
                Label(
                    model.isCreatingNewPackage ? "Ready for first save" : "Activatable",
                    systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Fix errors before saving", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            Text("\(model.validation.issues.filter { $0.severity == .error }.count) errors")
            Text("·")
            Text("\(model.validation.issues.filter { $0.severity == .warning }.count) advisories")
            Spacer()
            if let status = model.status {
                Text(status)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func revertOrDiscard() {
        let closesUnsavedWindow = model.isCreatingNewPackage
        model.revert()
        if closesUnsavedWindow {
            dismissWindow()
        }
    }

    private func issueCount(for stage: AbilityStudioEditorStage) -> Int {
        model.validation.issues.filter {
            $0.severity == .error && Self.stage(for: $0) == stage
        }.count
    }

    static func stage(for issue: SchemaIssue) -> AbilityStudioEditorStage {
        let path = issue.path
        if path.contains("plugin.application") {
            return .actions
        }
        if path.contains("plugin.operations")
            || path.contains("plugin.adapter")
        {
            return .actions
        }
        if path.contains("skills")
            || path.contains("capabilities")
            || path.contains("valueTypes")
            || path.contains("interactions")
            || path.contains("perceptions")
            || path.contains("totemProjections")
            || path.contains("dependencies") {
            return .wiring
        }
        if path.contains("routing")
            || path.contains("triggers")
            || path.contains("operatingPolicy") {
            return .intent
        }
        return .identity
    }
}

// The typed-window wrapper is gone with the second window. What remains of this
// file is the five-stage editor, still compiled but no longer reachable; its
// stages are replaced pane by pane and the file is deleted at the end.

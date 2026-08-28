import MaryBrain
import SwiftUI

struct AbilityStudioEditorIssueInspector: View {
    @ObservedObject var model: AbilityStudioViewModel
    @Binding var showsWarnings: Bool
    let onNavigate: (AbilityStudioEditorStage) -> Void

    private var presentation: AbilityStudioValidationPresentation {
        AbilityStudioValidationPresentation(validation: model.validation)
    }

    private var errors: [SchemaIssue] { presentation.errors }
    private var warnings: [SchemaIssue] {
        presentation.actionableWarnings + presentation.coverageGroups.flatMap(\.issues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("VALIDATION")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(errors.isEmpty ? "Package is valid" : "\(errors.count) errors")
                    .font(.headline)
                    .foregroundStyle(errors.isEmpty ? .green : .red)
                if !warnings.isEmpty {
                    Button(showsWarnings ? "Hide advisories" : "Show \(warnings.count) advisories") {
                        showsWarnings.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(15)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if errors.isEmpty && (!showsWarnings || warnings.isEmpty) {
                        ContentUnavailableView(
                            "No blocking issues",
                            systemImage: "checkmark.circle",
                            description: Text("The draft can activate. Expand advisories to review non-blocking coverage and authoring notes."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                    ForEach(errors) { issue in
                        issueCard(issue)
                    }
                    if showsWarnings {
                        ForEach(presentation.coverageGroups) { group in
                            DisclosureGroup("\(group.packageID.rawValue) provider coverage · \(group.unavailableSkillCount)") {
                                Text("These are not package errors. Portable Skills remain installed and honestly blocked until some application Ability realizes them.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 5)
                                ForEach(group.issues) { issue in issueCard(issue) }
                            }
                            .padding(10)
                            .foregroundStyle(.blue)
                            .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    if showsWarnings {
                        ForEach(presentation.actionableWarnings) { issue in issueCard(issue) }
                    }
                }
                .padding(12)
            }
        }
        .background(.regularMaterial)
    }

    private func issueCard(_ issue: SchemaIssue) -> some View {
        Button {
            onNavigate(AbilityStudioEditorView.stage(for: issue))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: issue.severity == .error
                          ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    Text(issue.code)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                }
                Text(issue.message)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                Text(issue.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(9)
            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
            .background(
                (issue.severity == .error ? Color.red : Color.orange).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct AbilityStudioAdvancedSchemaEditor: View {
    @ObservedObject var model: AbilityStudioViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "curlybraces.square.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("The visual editor and this source are the same document.")
                        .font(.callout.weight(.semibold))
                    Text("Unknown fields and executable content fail closed. If the source stops decoding, visual editing pauses until it is repaired here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.blue.opacity(0.07))
            Divider()
            TextEditor(text: Binding(
                get: { model.draft },
                set: { model.updateDraft($0) }))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
        }
    }
}

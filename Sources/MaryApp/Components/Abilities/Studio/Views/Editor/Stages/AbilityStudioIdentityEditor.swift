import MaryBrain
import SwiftUI

struct AbilityStudioIdentityEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    var body: some View {
        AbilityStudioStageScroll(
            title: "What kind of Ability is this?",
            introduction: "An Ability owns meaning and policy. It may use an installed compiled faculty or carry bounded Remote Hands recipes, but the `.mary` file itself is always data.") {
            AbilityStudioEditorSection("Role", symbol: "person.crop.circle.badge.questionmark") {
                Picker("Paradigm", selection: draftBinding(
                    package.paradigm,
                    model: model,
                    set: { $0.ability.paradigm = $1 })) {
                    ForEach(AbilityParadigm.allCases, id: \.self) { paradigm in
                        Text(paradigm.label).tag(paradigm)
                    }
                }
                .pickerStyle(.segmented)
                Text(package.paradigm.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                AbilityStudioSchemaPath("ability.paradigm")
            }

            AbilityStudioEditorSection("Identity", symbol: "shippingbox") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    AbilityStudioTextField(
                        "Title",
                        path: "ability.title",
                        text: draftBinding(package.ability.title, model: model) { draft, value in
                            draft.ability.title = value
                            draft.plugin?.title = value
                        })
                    AbilityStudioTextField(
                        "Version",
                        path: "package.version · ability.version",
                        text: draftBinding(package.package.version.rawValue, model: model) { draft, value in
                            draft.package.version = SemanticVersion(value)
                            draft.ability.version = SemanticVersion(value)
                            draft.plugin?.version = SemanticVersion(value)
                        },
                        monospaced: true)
                        .frame(maxWidth: 180)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Package identifier").font(.caption.weight(.medium))
                        Text(package.package.id.rawValue)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        Text("Fixed once installed so edits cannot silently become another package.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        AbilityStudioSchemaPath("package.id · ability.id")
                    }
                    AbilityStudioTextField(
                        "Publisher",
                        path: "package.publisher",
                        text: draftBinding(package.package.publisher, model: model) {
                            $0.package.publisher = $1
                        })
                }
                AbilityStudioTextArea(
                    "Summary",
                    path: "package.summary · ability.summary",
                    text: draftBinding(package.ability.summary, model: model) { draft, value in
                        draft.ability.summary = value
                        draft.package.summary = value
                    })
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Circle()
                        .fill(Color.maryAbilityTint(package.ability.tint))
                        .frame(width: 32, height: 32)
                    AbilityStudioTextField(
                        "Tint",
                        path: "ability.tint",
                        text: draftBinding(package.ability.tint, model: model) {
                            $0.ability.tint = $1
                        },
                        monospaced: true)
                }
            }

            if package.plugin == nil {
                AbilityStudioApplicationAffinityEditor(model: model, package: package)
            } else {
                AbilityStudioEditorSection("Application expertise", symbol: "app.badge") {
                    Label(
                        "This Ability's application identity is owned by its Remote Hands stage.",
                        systemImage: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                    Text(package.plugin?.application.title ?? "Application")
                        .font(.headline)
                }
            }
        }
    }
}

private struct AbilityStudioApplicationAffinityEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    private var applications: [ApplicationAffinity] { package.ability.applications ?? [] }
    private var pinnedApplicationIDs: Set<String> {
        AbilityStudioEditorIntegrity.pinnedInstalledApplicationIDs(
            in: package,
            snapshot: model.snapshot)
    }

    var body: some View {
        AbilityStudioEditorSection(
            "Applications known through installed faculties",
            symbol: "app.connected.to.app.below.fill") {
            Text("Use this when the package describes application expertise while an already-installed compiled faculty supplies the hands.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(Array(applications.enumerated()), id: \.offset) { index, application in
                AbilityStudioBlockCard(number: index + 1, title: application.title, symbol: "app") {
                    if pinnedApplicationIDs.contains(application.id) {
                        LabeledContent("Logical id") {
                            Text(application.id).font(.body.monospaced())
                        }
                        LabeledContent("Title") { Text(application.title) }
                        LabeledContent("Bundle identifiers") {
                            Text(application.bundleIdentifiers.joined(separator: ", "))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        Label(
                            "Pinned to the installed faculty's source application identity.",
                            systemImage: "lock.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        AbilityStudioTextField(
                            "Logical id",
                            path: "ability.applications[\(index)].id",
                            text: Binding(
                                get: { application.id },
                                set: { next in
                                    model.mutateValidatedEditorPackage {
                                        try AbilityStudioEditorIntegrity
                                            .renameApplicationAffinity(
                                                in: &$0,
                                                from: application.id,
                                                to: next)
                                    }
                                }),
                            monospaced: true)
                        AbilityStudioTextField(
                            "Title",
                            path: "ability.applications[\(index)].title",
                            text: Binding(
                                get: { application.title },
                                set: { value in
                                    model.mutateDraftPackage { draft in
                                        guard let row = draft.ability.applications?
                                            .firstIndex(where: { $0.id == application.id })
                                        else { return }
                                        draft.ability.applications?[row].title = value
                                    }
                                }))
                        AbilityStudioTagEditor(
                            title: "Bundle identifiers",
                            path: "ability.applications[\(index)].bundleIdentifiers",
                            values: application.bundleIdentifiers) { values in
                                model.mutateDraftPackage { draft in
                                    guard let row = draft.ability.applications?
                                        .firstIndex(where: { $0.id == application.id })
                                    else { return }
                                    draft.ability.applications?[row].bundleIdentifiers = values
                                }
                            }
                        HStack {
                            Spacer()
                            Button("Remove", role: .destructive) {
                                model.mutateDraftPackage { draft in
                                    draft.ability.applications?.removeAll {
                                        $0.id == application.id
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Button("Add Application") {
                model.mutateDraftPackage { draft in
                    var applications = draft.ability.applications ?? []
                    let nextID = abilityStudioFirstUnusedName(
                        stem: "application",
                        existing: applications.map(\.id))
                    applications.append(.init(id: nextID, title: "Application"))
                    draft.ability.applications = applications
                }
            }
        }
    }
}

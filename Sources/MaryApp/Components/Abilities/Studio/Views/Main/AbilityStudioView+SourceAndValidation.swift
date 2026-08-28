//
//  AbilityStudioView+SourceAndValidation.swift
//

import MaryBrain
import SwiftUI

extension AbilityStudioView {

    @ViewBuilder
    func providerRealization(
        _ realization: AbilityStudioProviderRealizationPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(
                    realization.provider.pluginTitle,
                    systemImage: providerClassIcon(realization.provider.pluginClass))
                    .font(.headline)
                Spacer()
                Text(providerClassLabel(realization.provider.pluginClass))
                    .foregroundStyle(.secondary)
            }
            Text("\(realization.activeSkillCount) active of \(realization.realizedSkillCount) realized Skill\(realization.realizedSkillCount == 1 ? "" : "s")")
                .monospacedDigit()
            if !realization.isAvailable {
                Label(
                    realization.unavailableReason ?? "Provider is not active on this Mac.",
                    systemImage: "exclamationmark.lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let carryingPackage = realization.provider.originPackageID {
                Text("Carried by \(carryingPackage.rawValue) \(realization.provider.originPackageVersion?.rawValue ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let applicationID = realization.provider.applicationID {
                Text("Application \(applicationID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !realization.bundleIdentifiers.isEmpty {
                identifierList(realization.bundleIdentifiers)
            }
            if !realization.bundleNames.isEmpty {
                Text("Declared bundles: \(realization.bundleNames.joined(separator: ", "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let resolution = realization.applicationResolution {
                Label(
                    applicationStatusLabel(resolution.status),
                    systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(applicationStatusColor(resolution.status))
                if let url = resolution.installedURL {
                    Text(url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !realization.requiredPermissions.isEmpty {
                Text("Permissions: \(realization.requiredPermissions.map(permissionLabel).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    var source: some View {
        VStack(spacing: 0) {
            if model.isLocalDraft {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                    Text("Edit freely. Save creates an unsigned local override; Mary leaves the bundled, source, or signed original unchanged.")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.blue.opacity(0.08))
                Divider()
            }
            TextEditor(text: Binding(
                get: { model.draft },
                set: { model.updateDraft($0) }
            ))
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            Divider()
            validationBar
        }
    }

    var validationBar: some View {
        let presentation = AbilityStudioValidationPresentation(validation: model.validation)
        return ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                if presentation.errors.isEmpty {
                    Label(
                        presentation.actionableWarnings.isEmpty
                            ? "Package and active graph valid"
                            : "Package valid with \(presentation.actionableWarnings.count) authoring warning\(presentation.actionableWarnings.count == 1 ? "" : "s")",
                        systemImage: presentation.actionableWarnings.isEmpty
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(presentation.actionableWarnings.isEmpty ? .green : .orange)
                } else {
                    Label(
                        "\(presentation.errors.count) error\(presentation.errors.count == 1 ? "" : "s") must be fixed before saving",
                        systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }

                ForEach(presentation.errors) { issue in
                    validationIssue(issue, color: .red)
                }
                ForEach(presentation.actionableWarnings) { issue in
                    validationIssue(issue, color: .orange)
                }

                ForEach(presentation.coverageGroups) { group in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("These portable Skills remain declared and visible in the registry. They will execute only after an application Ability supplies a matching native realization.")
                                .foregroundStyle(.secondary)
                            ForEach(group.skillIDs, id: \.self) { skillID in
                                Text(skillID.rawValue)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Label(
                            "\(coverageTitle(group.packageID)) provider coverage · \(group.unavailableSkillCount) portable Skill\(group.unavailableSkillCount == 1 ? "" : "s") safely blocked",
                            systemImage: "square.stack.3d.up")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxHeight: 210)
        .background(.bar)
    }

    func validationIssue(_ issue: SchemaIssue, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(issue.severity.rawValue.uppercased()) · \(issue.path)")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
            Text(issue.message)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(color)
        .textSelection(.enabled)
    }

    func coverageTitle(_ packageID: PackageID) -> String {
        if let record = model.snapshot.package(id: packageID) {
            return record.package.ability.title
        }
        return packageID.rawValue
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

}

//
//  AbilityStudioView+Labels.swift
//

import MaryBrain
import SwiftUI

extension AbilityStudioView {

    func studioSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func schemaRows(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if values.isEmpty { Text("None").foregroundStyle(.tertiary) }
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text("\(index + 1). \(value)")
            }
        }
    }

    func metric(_ title: String, _ value: Int) -> some View {
        HStack { Text(title); Spacer(); Text("\(value)").monospacedDigit() }
    }

    func providerClassLabel(_ providerClass: PluginProviderClass) -> String {
        AbilityRealizationPresentation(providerClass).label
    }

    func providerClassIcon(_ providerClass: PluginProviderClass) -> String {
        AbilityRealizationPresentation(providerClass).symbol
    }

    /// The role, application expertise, and composed discipline in one line.
    static func paradigmDetail(_ package: MaryAbilityPackage) -> String {
        AbilityParadigmPresentation(package.paradigm).detailLabel(
            applications: package.applicationAffinities,
            extending: package.extendedDisciplines.map(\.rawValue))
    }

    func realizationCountLabel(
        _ application: AbilityStudioApplicationPresentation
    ) -> String {
        if application.activeRealizedSkillCount == application.declaredRealizedSkillCount {
            return "\(application.activeRealizedSkillCount) active"
        }
        return "\(application.activeRealizedSkillCount) active of \(application.declaredRealizedSkillCount) declared"
    }

    func activationLabel(_ activation: PluginApplicationActivation) -> String {
        switch activation {
        case .activateRunning: return "Bring forward if already running"
        case .requireFrontmost: return "Require the app to be frontmost"
        }
    }

    func applicationStatusLabel(
        _ status: PluginApplicationResolution.Status
    ) -> String {
        switch status {
        case .running: return "Running"
        case .ambiguous: return "Ambiguous"
        case .installed: return "Installed"
        case .notFound: return "Not found"
        }
    }

    func applicationStatusColor(
        _ status: PluginApplicationResolution.Status
    ) -> Color {
        switch status {
        case .running: return .green
        case .ambiguous: return .red
        case .installed: return .blue
        case .notFound: return .orange
        }
    }

    func permissionLabel(_ permission: PermissionKind) -> String {
        switch permission {
        case .screenRecording: return "Screen Recording"
        case .speechRecognition: return "Speech Recognition"
        default:
            return permission.rawValue.prefix(1).uppercased()
                + permission.rawValue.dropFirst()
        }
    }

    @ViewBuilder
    func permissionList(_ permissions: [PermissionKind]) -> some View {
        if permissions.isEmpty {
            Text("None")
                .foregroundStyle(.secondary)
        } else {
            ForEach(permissions, id: \.self) { permission in
                Label(permissionLabel(permission), systemImage: "lock.shield")
            }
        }
    }

    func identifierList(_ identifiers: [String]) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(identifiers, id: \.self) { identifier in
                Text(identifier)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    func trustIcon(_ status: AbilityPackageTrustStatus) -> String {
        switch status {
        case .bundled: return "checkmark.shield.fill"
        case .developmentSource: return "hammer.fill"
        case .installedSigned: return "signature"
        case .installedUnsigned: return "exclamationmark.shield"
        }
    }

    func provenanceLabel(_ record: AbilityPackageRecord) -> String {
        isActiveLocalOverride(record) ? "Local override" : record.trustStatus.label
    }

    func provenanceDetail(_ record: AbilityPackageRecord) -> String {
        isActiveLocalOverride(record)
            ? "Saved locally in Application Support. It overrides the immutable base package without changing it."
            : record.trustStatus.detail
    }

    func isActiveLocalOverride(_ record: AbilityPackageRecord) -> Bool {
        record.source == .installed
            && record.sourceURL.deletingLastPathComponent().lastPathComponent == "Overrides"
    }

}

//
//  AbilityStudioEditorActions+Helpers.swift
//

import AppKit
import MaryBrain
import SwiftUI
import UniformTypeIdentifiers

extension AbilityStudioActionsEditor {

    func actionCoverage(
        _ coverage: AbilityStudioActionCoveragePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                coverageMetric(
                    coverage.remoteHandsActionCount,
                    label: "remote-hand actions",
                    color: .blue)
                coverageMetric(
                    coverage.localSkillCount,
                    label: "local Skills",
                    color: .purple)
                coverageMetric(
                    coverage.dependencyImplementationCount,
                    label: "portable implementations",
                    color: .green)
                coverageMetric(
                    coverage.missingDependencySkillCount,
                    label: "not implemented",
                    color: coverage.missingDependencySkillCount == 0 ? .green : .orange)
                Spacer(minLength: 0)
            }
            Text("Every action shown here runs through Mary's one macUI remote-hands interpreter.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if coverage.missingDependencySkillCount > 0 {
                Text("\(coverage.missingDependencySkillCount) portable Skill contracts in declared dependencies remain installed but safely unavailable through this application. Implement compatible contracts here; contracts needing richer typed behavior stay visibly blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    func coverageMetric(
        _ value: Int,
        label: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))
    }

    func ownershipColor(
        _ ownership: AbilityStudioActionCoveragePresentation.ActionOwnership
    ) -> Color {
        switch ownership {
        case .local: return .purple
        case .portable: return .blue
        case .unresolved: return .orange
        }
    }

    var runningApplications: [(
        title: String,
        bundleID: String,
        shortVersion: String?,
        bundleVersion: String?
    )] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier else { return nil }
                let bundle = application.bundleURL.flatMap(Bundle.init(url:))
                return (
                    application.localizedName ?? bundleID,
                    bundleID,
                    bundle?.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String,
                    bundle?.object(forInfoDictionaryKey: "CFBundleVersion")
                        as? String)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func insetField(
        _ title: String,
        value: Double,
        mutate: @escaping (inout MaryAbilityPackage, Double) -> Void
    ) -> some View {
        AbilityStudioDoubleField(title, path: "", value: value, range: 0...1_000) { next in
            model.mutateDraftPackage { mutate(&$0, next) }
        }
    }

    func addPluginPlugin() {
        model.mutateDraftPackage { draft in
            let id = draft.package.id.rawValue
            draft.ability.paradigm = .applicationExpertise
            draft.plugin = .init(
                id: id,
                version: draft.package.version,
                title: draft.ability.title,
                application: .init(
                    id: id,
                    title: draft.ability.title,
                    aliases: [],
                    bundleIdentifiers: [],
                    bundleNames: [],
                    targetClasses: ["\(id)-application"],
                    activation: .activateRunning),
                adapter: .init(
                    id: AdapterID("\(id).managed-ui"),
                    version: draft.package.version,
                    title: "\(draft.ability.title) Native UI"),
                operations: [],
                realizations: [])
        }
    }

    func applyApplication(
        title: String,
        bundleID: String,
        bundleName: String,
        shortVersion: String? = nil,
        bundleVersion: String? = nil
    ) {
        model.mutateDraftPackage { draft in
            draft.plugin?.application.title = title
            draft.plugin?.title = title
            draft.plugin?.application.bundleIdentifiers = [bundleID]
            draft.plugin?.application.bundleNames = [bundleName]
            if let shortVersion, let bundleVersion {
                draft.plugin?.application.supportedReleases = [.init(
                    shortVersion: shortVersion,
                    bundleVersion: bundleVersion)]
            }
            if draft.plugin?.application.aliases.isEmpty == true {
                draft.plugin?.application.aliases = [title.lowercased()]
            }
        }
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier else { return }
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        applyApplication(
            title: displayName,
            bundleID: identifier,
            bundleName: url.lastPathComponent,
            shortVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundleVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    func addOperation(_ plugin: PluginSchema) {
        let targetClasses = plugin.application.targetClasses.first.map { [$0] } ?? []
        let didAdd = model.mutateAuthoringDocument { document in
            try document.addRemoteHandsAction(
                title: "New Remote Hands Action",
                summary: "Describe the visible result of this bounded action.",
                steps: [.init(id: "settle", kind: .wait, durationSeconds: 0.1)],
                targetClasses: targetClasses)
        }
        if didAdd { selectedOperation = plugin.operations.count }
    }

    func removeOperation(_ operation: String) {
        model.mutateAuthoringDocument { document in
            try document.removeOperation(operation)
        }
    }

    func selectCreatedOperation(_ operation: String) {
        guard let operations = model.draftPackage?.plugin?.operations,
              let index = operations.firstIndex(where: {
                  $0.operation == operation
              }) else { return }
        selectedOperation = index
    }

}

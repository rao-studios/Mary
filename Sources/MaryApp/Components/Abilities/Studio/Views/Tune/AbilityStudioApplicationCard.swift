//
//  AbilityStudioApplicationCard.swift
//  Mary
//
//  WHAT: The application this expertise teaches, and whether Mary may bring it forward.
//  IN:   AbilityStudioTunePane.
//  OUT:  mutateDraftPackage; logical id rename via renameApplicationAffinity.
//  PIN:  Bundle identity selects the process. Titles and aliases help routing;
//        they never authorize a different application.
//

import AppKit
import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioApplicationCard: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    private var plugin: PluginSchema? { package.plugin }

    /// Applications supplied by an installed faculty are not this package's to
    /// rename; the Studio shows them as given.
    private var isPinned: Bool {
        guard let application = plugin?.application else { return false }
        return AbilityStudioEditorIntegrity
            .pinnedInstalledApplicationIDs(in: package, snapshot: model.snapshot)
            .contains(application.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: .layer2) {
            StudioLabel("Teaches")
                .frame(width: 78, alignment: .leading)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: .layer2) {
                if let plugin {
                    identity(plugin)
                    activation(plugin)
                    resolution
                } else {
                    affinitiesOnly
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Identity

    private func identity(_ plugin: PluginSchema) -> some View {
        VStack(alignment: .leading, spacing: .layer2) {
            HStack(spacing: .layer2) {
                StudioField(
                    value: plugin.application.title,
                    placeholder: "Application name",
                    isEditable: !isPinned
                ) { next in
                    model.mutateDraftPackage { draft in
                        draft.plugin?.application.title = next
                        draft.plugin?.title = next
                    }
                }
                .id(package.package.id)
                if !isPinned { runningApplicationMenu }
            }
            StudioChipEditor(
                values: plugin.application.bundleIdentifiers,
                placeholder: "com.example.app",
                isEditable: !isPinned
            ) { next in
                model.mutateDraftPackage { $0.plugin?.application.bundleIdentifiers = next }
            }
            if isPinned {
                StudioNote("Supplied by an installed faculty, so its identity is not this ability's to change.")
            }
        }
    }

    private var runningApplicationMenu: some View {
        Menu {
            ForEach(runningApplications, id: \.bundleID) { application in
                Button(application.title) { apply(application) }
            }
            Divider()
            Button("Choose an app…", action: chooseApplication)
        } label: {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(Color.maryInk.opacity(0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pick a running application")
    }

    private func activation(_ plugin: PluginSchema) -> some View {
        StudioMenuPicker(
            label: nil,
            value: plugin.application.activation,
            options: PluginApplicationActivation.allCases,
            title: AbilityStudioLabels.activation
        ) { next in
            model.mutateDraftPackage { $0.plugin?.application.activation = next }
        }
    }

    @ViewBuilder
    private var resolution: some View {
        if let application = model.selectedApplication {
            let status = application.applicationResolution.status
            HStack(spacing: 5) {
                Circle()
                    .fill(AbilityStudioLabels.applicationStatusColor(status))
                    .frame(width: 6, height: 6)
                Text(AbilityStudioLabels.applicationStatus(status))
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.55))
                if application.declaredRealizedSkillCount > 0 {
                    Text("· \(application.activeRealizedSkillCount) of \(application.declaredRealizedSkillCount) skills active")
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.4))
                }
            }
        }
    }

    /// A package with application affinity but no Plugin — it names the app for
    /// routing without carrying hands for it.
    private var affinitiesOnly: some View {
        VStack(alignment: .leading, spacing: .layer2) {
            ForEach(package.applicationAffinities, id: \.id) { affinity in
                HStack(spacing: .layer2) {
                    Text(affinity.title)
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryInk)
                    Text(affinity.bundleIdentifiers.joined(separator: ", "))
                        .font(.maryMono(9))
                        .foregroundStyle(Color.maryInk.opacity(0.45))
                }
            }
            StudioNote("Named for routing only — this ability carries no hands of its own for it.")
        }
    }

    // MARK: - Applying

    private var runningApplications: [(
        title: String,
        bundleID: String,
        shortVersion: String?,
        bundleVersion: String?
    )] {
        _ = model.applicationResolutionEpoch
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier else { return nil }
                let bundle = application.bundleURL.flatMap(Bundle.init(url:))
                return (
                    application.localizedName ?? bundleID,
                    bundleID,
                    bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func apply(
        _ application: (
            title: String,
            bundleID: String,
            shortVersion: String?,
            bundleVersion: String?
        )
    ) {
        model.mutateDraftPackage { draft in
            draft.plugin?.application.title = application.title
            draft.plugin?.title = application.title
            draft.plugin?.application.bundleIdentifiers = [application.bundleID]
            draft.plugin?.application.bundleNames = ["\(application.title).app"]
            // A verified release is evidence the recipes were authored against
            // this exact build, so it only makes sense with both halves.
            if let short = application.shortVersion, let build = application.bundleVersion {
                draft.plugin?.application.supportedReleases = [
                    .init(shortVersion: short, bundleVersion: build),
                ]
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier
        else { return }
        apply((
            title: url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundleVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String))
    }
}

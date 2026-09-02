//
//  AbilityStudioNewPackageSheet.swift
//  Mary
//
//  WHAT: Teach Mary one application. The Studio's only creation lane.
//  IN:   AbilityStudioView rail footer.
//  OUT:  AbilityStudioPackageFactory.nativeApplication → model.openNewPackage
//  PIN:  A discipline needs adapters compiled into Mary, so the Studio cannot
//        author one. That is a statement about hands, not a missing feature.
//

import AppKit
import MaryBrain
import SwiftUI

@MainActor
struct AbilityStudioNewPackageSheet: View {
    @ObservedObject var model: AbilityStudioViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var packageID = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var selectedBundleID = ""
    @State private var manualBundleID = ""
    @State private var creationError: String?

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return (app.localizedName ?? bundleID, bundleID)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .layer4) {
            header

            MaryCard(padding: .layer4) {
                VStack(alignment: .leading, spacing: .layer3) {
                    HStack(spacing: .layer2) {
                        Image(systemName: "macwindow.badge.plus")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.maryGold)
                        Text("Teach an application")
                            .font(.marySans(12, weight: .medium))
                            .foregroundStyle(Color.maryInk)
                        Spacer()
                    }
                    StudioNote(
                        "Mary learns one application through bounded hands — key presses, typing, pointer moves, scrolling and waits. Disciplines like Coding or Multimedia ship with Mary, because their skills need faculties compiled into the app; your expertise realizes those skills for this application.")
                }
            }

            VStack(alignment: .leading, spacing: .layer3) {
                StudioField(
                    "Application",
                    value: appLabel,
                    placeholder: "Pick a running application",
                    isEditable: false
                ) { _ in }
                .overlay(alignment: .trailing) { applicationMenu.padding(.trailing, 6) }

                if selectedBundleID.isEmpty {
                    StudioField(
                        "Bundle identifier",
                        value: manualBundleID,
                        placeholder: "com.example.app",
                        mono: true
                    ) { manualBundleID = $0 }
                }

                HStack(alignment: .top, spacing: .layer3) {
                    StudioField("Name", value: title, placeholder: "Spotify") { next in
                        title = next
                        if packageID.isEmpty {
                            packageID = AbilityStudioPackageFactory.portableStem(next, fallback: "")
                        }
                    }
                    StudioField("Identifier", value: packageID, placeholder: "spotify", mono: true) {
                        packageID = $0
                    }
                }

                StudioField(
                    "What should this ability help with?",
                    value: summary,
                    placeholder: "Play music, browse a library, drive the transport…"
                ) { summary = $0 }
            }

            if let creationError {
                HStack(alignment: .top, spacing: .layer2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.maryError)
                    Text(creationError)
                        .font(.marySans(11))
                        .foregroundStyle(Color.maryError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: .layer2) {
                StudioNote("Nothing is installed until the first save.")
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.maryQuiet)
                Button("Create", action: create)
                    .buttonStyle(.mary)
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.4)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.layer5)
        .frame(width: 520, height: 520)
        .background(Color.maryBG)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: .layer2) {
            MaryMark(size: 18)
            Text("Create an ability")
                .font(.marySerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.maryInk)
            Spacer()
        }
    }

    private var appLabel: String {
        guard !selectedBundleID.isEmpty else { return "" }
        return runningApps.first { $0.bundleID == selectedBundleID }?.name ?? selectedBundleID
    }

    private var applicationMenu: some View {
        Menu {
            Button("Enter a bundle identifier…") { selectedBundleID = "" }
            Divider()
            ForEach(runningApps, id: \.bundleID) { app in
                Button(app.name) {
                    selectedBundleID = app.bundleID
                    if title.isEmpty {
                        title = app.name
                        packageID = AbilityStudioPackageFactory.portableStem(app.name, fallback: "")
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.maryInk.opacity(0.45))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var effectiveBundleID: String {
        selectedBundleID.isEmpty ? manualBundleID : selectedBundleID
    }

    private var canCreate: Bool {
        !packageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !effectiveBundleID.isEmpty
    }

    private func create() {
        creationError = nil
        do {
            var package = try AbilityStudioPackageFactory.nativeApplication(.init(
                packageID: PackageID(packageID.trimmingCharacters(in: .whitespacesAndNewlines)),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                bundleIdentifier: effectiveBundleID,
                bundleName: runningApps.first { $0.bundleID == effectiveBundleID }?.name))
            let authored = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !authored.isEmpty {
                package.package.summary = authored
                package.ability.summary = authored
            }
            guard model.openNewPackage(package) else {
                creationError = model.status ?? "Mary could not create this ability."
                return
            }
            dismiss()
        } catch {
            creationError = error.localizedDescription
        }
    }
}

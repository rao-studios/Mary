import AppKit
import MaryBrain
import SwiftUI

// MARK: - New package

struct AbilityStudioNewPackageSheet: View {
    @ObservedObject var model: AbilityStudioViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var kind: AbilityStudioAuthoringKind = .packageOwnedNativeApplication
    @State private var selectedBundleID = ""
    @State private var manualBundleID = ""
    @State private var packageID = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var selectedFacultyID = ""
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

    private var installedOptions: [AbilityStudioInstalledFacultyOption] {
        AbilityStudioAuthoringCatalog.installedFaculties(in: model.snapshot)
    }

    private var selectedFaculty: AbilityStudioInstalledFacultyOption? {
        installedOptions.first { $0.id == selectedFacultyID }
            ?? installedOptions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create an Ability").font(.title2.bold())
                Text("Start visually. The result is a complete, portable `.mary` schema — never editor-only project data.")
                    .foregroundStyle(.secondary)
            }

            Picker("Authoring model", selection: $kind) {
                Label("Teach an Application", systemImage: "hand.point.up.left.fill")
                    .tag(AbilityStudioAuthoringKind.packageOwnedNativeApplication)
                Label("Use an Installed Faculty", systemImage: "puzzlepiece.extension.fill")
                    .tag(AbilityStudioAuthoringKind.installedFaculty)
            }
            .pickerStyle(.segmented)

            GroupBox {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        kind == .packageOwnedNativeApplication
                            ? "Package-owned Remote Hands"
                            : "Installed compiled faculty",
                        systemImage: kind == .packageOwnedNativeApplication
                            ? "cursorarrow.motionlines" : "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Text(kind == .packageOwnedNativeApplication
                        ? "The file teaches Mary one application using bounded text and keyboard entry, pointer movement and gestures, scrolling, cleanup, waits, and native postconditions."
                        : "The file owns intent, policy, Skills, and typed contracts, then binds them to an operation published by a compiled faculty already installed in Mary.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Section("Package") {
                    TextField("Package id (lower-case slug)", text: $packageID)
                    TextField("Title", text: $title)
                    TextField("What should this Ability help with?", text: $summary)
                }

                if kind == .packageOwnedNativeApplication {
                    Section("Target application") {
                        Picker("Running application", selection: $selectedBundleID) {
                            Text("Enter bundle id manually…").tag("")
                            ForEach(runningApps, id: \.bundleID) { app in
                                Text("\(app.name) — \(app.bundleID)").tag(app.bundleID)
                            }
                        }
                        if selectedBundleID.isEmpty {
                            TextField("Bundle identifier (com.example.app)", text: $manualBundleID)
                        }
                    }
                } else {
                    Section("Installed Mary faculty") {
                        if installedOptions.isEmpty {
                            Label(
                                "No available compiled faculty currently has a validated callable Skill contract to compose.",
                                systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Picker("Validated contract", selection: Binding(
                                get: {
                                    selectedFaculty?.id ?? ""
                                },
                                set: { selectedFacultyID = $0 })) {
                                ForEach(installedOptions) { faculty in
                                    Text("\(faculty.manifest.title) · \(faculty.runtimeSkill.ability.title) / \(faculty.runtimeSkill.skill.title)")
                                        .tag(faculty.id)
                                }
                            }
                            if let faculty = selectedFaculty {
                                LabeledContent("Exact operation") {
                                    Text(faculty.operation.operation)
                                        .font(.body.monospaced())
                                }
                                LabeledContent("Contract source") {
                                    Text("\(faculty.sourcePackage.ability.title) · \(faculty.runtimeSkill.skill.title)")
                                }
                                LabeledContent("Policy inherited") {
                                    Text("\(faculty.runtimeSkill.skill.modelExposure.parameters.count) parameters · \(faculty.runtimeSkill.skill.inputs.count) inputs · \(faculty.runtimeSkill.skill.outputs.count) outputs · \(faculty.runtimeSkill.skill.requirements.capabilities.count) capabilities")
                                }
                                Text("Compiled provider · \(faculty.manifest.transport.rawValue) boundary · \(faculty.runtimeSkill.skill.access.rawValue) access\(faculty.runtimeSkill.skill.usesStage ? " · owns stage" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Studio inherits the validated Skill's typed ports, model parameters, capability requirements, application identity, access level, stage ownership, and source dependency. You can refine its intent after creation without weakening that contract.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Label(
                "No JavaScript, shell command, executable source, control-bearing text, or author-defined output can be authored by either path.",
                systemImage: "checkmark.shield")
                .font(.footnote)
                .foregroundStyle(.green)
            if let creationError {
                Label(creationError, systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create & Open Editor", action: create)
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 650, minHeight: 590)
    }

    private var effectiveBundleID: String {
        selectedBundleID.isEmpty ? manualBundleID : selectedBundleID
    }

    private var canCreate: Bool {
        let baseReady = !packageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch kind {
        case .packageOwnedNativeApplication:
            return baseReady && !effectiveBundleID.isEmpty
        case .installedFaculty:
            return baseReady && selectedFaculty != nil
        }
    }

    private func create() {
        do {
            creationError = nil
            let package: MaryAbilityPackage
            switch kind {
            case .packageOwnedNativeApplication:
                var native = try AbilityStudioPackageFactory.nativeApplication(.init(
                    packageID: PackageID(packageID),
                    title: title,
                    bundleIdentifier: effectiveBundleID,
                    bundleName: runningApps.first {
                        $0.bundleID == effectiveBundleID
                    }?.name))
                let authoredSummary = summary
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !authoredSummary.isEmpty {
                    native.package.summary = authoredSummary
                    native.ability.summary = authoredSummary
                }
                package = native
            case .installedFaculty:
                guard let faculty = selectedFaculty else { return }
                let authoredSummary = summary
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                package = try AbilityStudioPackageFactory.installedFaculty(.init(
                    packageID: PackageID(packageID),
                    title: title,
                    summary: authoredSummary.isEmpty
                        ? "Uses \(faculty.manifest.title) to perform \(faculty.runtimeSkill.skill.title)."
                        : authoredSummary,
                    faculty: faculty))
            }
            guard let request = model.editorRequestForNewPackage(package) else {
                creationError = model.status ?? "Mary could not create this package."
                return
            }
            dismiss()
            openWindow(id: "ability-editor", value: request)
        } catch {
            creationError = error.localizedDescription
            model.status = creationError
        }
    }
}

//
//  AbilityStudioView+DetailSections.swift
//

import MaryBrain
import SwiftUI

extension AbilityStudioView {

    func detail(_ record: AbilityPackageRecord) -> some View {
        VStack(spacing: 0) {
            header(record)
            TabView {
                overview(record)
                    .tabItem { Label("Overview", systemImage: "square.grid.2x2") }
                skills
                    .tabItem { Label("Skills", systemImage: "bolt.horizontal") }
                dependencies
                    .tabItem { Label("Dependencies", systemImage: "point.3.connected.trianglepath.dotted") }
                application
                    .tabItem { Label("Application", systemImage: "macwindow") }
                AbilityStudioRuntimeTab(model: model)
                    .tabItem { Label("Native", systemImage: "hand.point.up.left") }
                source
                    .tabItem { Label("Schema", systemImage: "curlybraces") }
            }
        }
    }

    func header(_ record: AbilityPackageRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Color.maryAbilityTint(
                        record.package.ability.tint, fallback: .accentColor))
                    .frame(width: 12, height: 12)
                Text(record.package.ability.title)
                    .font(.title2.weight(.semibold))
                Text(record.package.package.version.rawValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openWindow(
                        id: "ability-editor",
                        value: AbilityStudioEditorWindowRequest(packageID: record.id))
                } label: {
                    Label("Edit Visually", systemImage: "square.grid.2x2")
                }
                .disabled(model.isDirty)
                .help(model.isDirty
                    ? "Save or revert the Schema draft before opening the visual editor."
                    : "Open this package in the full visual Ability Editor.")
                Button("Export", action: model.exportPackage)
                Button("Revert", action: model.revert).disabled(!model.isDirty)
                Button("Validate", action: model.validateDraft)
                    .disabled(model.draft.isEmpty)
                Button("Save", action: model.save)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !model.canEditSelectedPackage
                            || !model.isDirty
                            || !model.validation.isValid)
            }
            Text(record.package.ability.summary)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                // THE ROLE, on every tab. A reader who opens Studio on the
                // Skills or Schema tab should still know whether they are
                // looking at a craft, expertise in one application, or
                // something that drives the computer itself.
                Label(
                    Self.paradigmDetail(record.package),
                    systemImage: AbilityParadigmPresentation(record.package.paradigm).symbol)
                    .help(record.package.paradigm.explanation)
                Label(provenanceLabel(record), systemImage: trustIcon(record.trustStatus))
                if model.isLocalDraft {
                    Label("Local override on save", systemImage: "pencil.and.outline")
                        .foregroundStyle(.blue)
                }
                Text("registry \(model.snapshot.revision.uuidString.prefix(8))")
                if model.isDirty { Text("unsaved").foregroundStyle(.orange) }
                if model.hasPendingRegistryUpdate {
                    Text("registry update pending").foregroundStyle(.orange)
                }
                Spacer()
                if let status = model.status {
                    Text(status).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding()
        .background(.bar)
    }

    func overview(_ record: AbilityPackageRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                studioSection("Operating policy") {
                    schemaRows("Phases", record.package.ability.operatingPolicy.phases)
                    schemaRows("Guardrails", record.package.ability.operatingPolicy.guardrails)
                    schemaRows("Success", record.package.ability.operatingPolicy.successSignals)
                    schemaRows("Stop", record.package.ability.operatingPolicy.stopConditions)
                }
                studioSection("Package trust") {
                    Label(provenanceLabel(record), systemImage: trustIcon(record.trustStatus))
                        .font(.headline)
                    Text(provenanceDetail(record))
                        .foregroundStyle(.secondary)
                    LabeledContent("Source") {
                        Text(record.sourceURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Requires Mary") {
                        Text(record.package.package.minimumMaryVersion?.rawValue ?? "Not declared")
                            .font(.system(.caption, design: .monospaced))
                    }
                    Text("Descriptions and operating-policy prose are inspector metadata. Mary compiles model instructions only from closed schema fields using application-owned wording.")
                        .foregroundStyle(.secondary)
                }
                studioSection("Schema graph") {
                    metric("Skills", record.package.skills.count)
                    metric("Capabilities", record.package.capabilities.count)
                    metric("Interactions", record.package.interactions.count)
                    metric("Perceptions", record.package.perceptions.count)
                    metric("Value types", record.package.valueTypes.count)
                    metric("Totem projections", record.package.totemProjections.count)
                }
                if !record.package.totemProjections.isEmpty {
                    studioSection("Totem projection plan") {
                        ForEach(record.package.totemProjections) { projection in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(projection.id.rawValue)
                                    .font(.system(.body, design: .monospaced))
                                Text("\(projection.purpose.rawValue) · \(projection.persistence.rawValue) · \(projection.lanes.map(\.rawValue).joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(projection.skills.isEmpty
                                    ? "Applies to every Skill"
                                    : "Skills: \(projection.skills.map(\.rawValue).joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                studioSection("Routing") {
                    Text("declared preference \(record.package.ability.routing.preference) · conflict \(record.package.ability.routing.conflictPolicy.rawValue)")
                        .font(.system(.body, design: .monospaced))
                    Text("Triggers: " + (record.package.ability.triggers.tokens
                        + record.package.ability.triggers.phrases).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var skills: some View {
        List(model.selectedSkills) { runtime in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(runtime.reference.displayLabel)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(runtime.availability.readiness.rawValue)
                        .foregroundStyle(runtime.availability.readiness == .blocked ? .red : .secondary)
                }
                Text(runtime.skill.summary).foregroundStyle(.secondary)
                if let binding = runtime.availability.selectedBinding {
                    Text("\(binding.adapterID.rawValue)/\(binding.operation)")
                        .font(.caption.monospaced())
                } else if !runtime.availability.reasons.isEmpty {
                    Text(runtime.availability.reasons.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    var dependencies: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                studioSection("Ability dependencies") {
                    if model.selectedDependencies.isEmpty {
                        Label(
                            "This Ability has no package dependencies.",
                            systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.selectedDependencies) { dependency in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(dependency.title)
                                        .font(.headline)
                                    Text(dependency.packageID.rawValue)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Label(
                                        dependency.isSatisfied ? "Ready" : "Unavailable",
                                        systemImage: dependency.isSatisfied
                                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(dependency.isSatisfied ? .green : .orange)
                                }
                                Text(
                                    "\(dependency.isOptional ? "Optional" : "Required") · version \(dependency.minimumVersion.rawValue) or newer")
                                    .foregroundStyle(.secondary)
                                if let installedVersion = dependency.installedVersion {
                                    Text("Installed \(installedVersion.rawValue)")
                                        .font(.caption.monospaced())
                                } else {
                                    Text("Not present in this active registry")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                studioSection("How Abilities work together") {
                    Text("Dependencies provide shared semantic Skills. An application Ability can realize those Skills without copying them or teaching the shared Ability about a particular app.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var application: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let application = model.selectedApplication {
                    studioSection("Provider") {
                        LabeledContent("Provider class") {
                            Label(
                                providerClassLabel(application.providerClass),
                                systemImage: providerClassIcon(application.providerClass))
                        }
                        LabeledContent("Plugin") {
                            Text("\(application.pluginTitle) · \(application.pluginID)")
                                .font(.system(.body, design: .monospaced))
                        }
                        LabeledContent("Carrying package") {
                            Text("\(application.carryingPackageID.rawValue) \(application.carryingPackageVersion.rawValue)")
                                .font(.system(.body, design: .monospaced))
                        }
                        LabeledContent(
                            application.adapters.count == 1 ? "Adapter" : "Adapters"
                        ) {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(application.adapters, id: \.id) { adapter in
                                    Text("\(adapter.id.rawValue) · \(adapter.engine.rawValue)")
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        }
                        LabeledContent("Realized Skills") {
                            Text(realizationCountLabel(application))
                                .monospacedDigit()
                        }
                        Text("This package teaches Mary an application through validated recipes. Mary owns and interprets the execution engine.")
                            .foregroundStyle(.secondary)
                    }
                    studioSection("Application identity") {
                        LabeledContent("Status") {
                            Label(
                                applicationStatusLabel(
                                    application.applicationResolution.status),
                                systemImage: "circle.fill")
                                .foregroundStyle(applicationStatusColor(
                                    application.applicationResolution.status))
                        }
                        LabeledContent("Application") {
                            Text(application.applicationResolution.displayName)
                        }
                        LabeledContent("Declared title") {
                            Text(application.applicationTitle)
                        }
                        LabeledContent("Logical identity") {
                            Text(application.applicationID)
                                .font(.system(.body, design: .monospaced))
                        }
                        if !application.bundleNames.isEmpty {
                            LabeledContent("Declared bundle names") {
                                identifierList(application.bundleNames)
                            }
                        }
                        LabeledContent("Bundle identifiers") {
                            identifierList(application.bundleIdentifiers)
                        }
                        // PROVENANCE, NOT PERMISSION. These tuples say what the
                        // author verified against; they no longer decide whether
                        // anything may run, so the label says "verified" and an
                        // unrecognised build is noted rather than coloured red.
                        LabeledContent("Verified against") {
                            if application.supportedReleases.isEmpty {
                                Text("Any release")
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .trailing, spacing: 2) {
                                    ForEach(
                                        Array(application.supportedReleases.enumerated()),
                                        id: \.offset
                                    ) { _, release in
                                        Text("\(release.shortVersion) (\(release.bundleVersion))")
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                }
                            }
                        }
                        if let observed = application.applicationResolution.observedRelease,
                           !application.applicationResolution.releaseIsVerified {
                            LabeledContent("Running") {
                                Text("\(observed.shortVersion) — not verified")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let matchedBundleIdentifier = application
                            .applicationResolution.matchedBundleIdentifier {
                            LabeledContent("Matched identity") {
                                Text(matchedBundleIdentifier)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        LabeledContent("Resolved location") {
                            if let url = application.applicationResolution.installedURL {
                                Text(url.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(application.applicationResolution.status == .running
                                    ? "Location unavailable for running process"
                                    : application.applicationResolution.status == .ambiguous
                                        ? "Multiple running processes match; no exact target selected"
                                        : "No installed application found")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !application.aliases.isEmpty {
                            LabeledContent("Voice aliases") {
                                Text(application.aliases.joined(separator: ", "))
                            }
                        }
                        LabeledContent("Activation") {
                            Text(activationLabel(application.activation))
                        }
                        Text("Application registration is automatic when this Ability loads. Native Plugin toggles in Settings do not gate Plugin applications. Mary discovers the app by exact bundle identity and never launches it during registration.")
                            .foregroundStyle(.secondary)
                    }
                    studioSection("Required Mac permissions") {
                        permissionList(application.requiredPermissions)
                        Text("The Ability requests these permissions; only macOS can grant them.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    studioSection("Application provider") {
                        Label(
                            "This Ability does not carry a Plugin application provider.",
                            systemImage: "square.stack.3d.up")
                        Text("It may define portable semantic Skills, use Native Plugins compiled into Mary, or be realized by another application Ability.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.selectedProviderRealizations.isEmpty {
                    studioSection("Skill implementations") {
                        ForEach(model.selectedProviderRealizations) { realization in
                            providerRealization(realization)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

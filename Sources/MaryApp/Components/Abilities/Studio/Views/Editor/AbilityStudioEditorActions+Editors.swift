//
//  AbilityStudioEditorActions+Editors.swift
//

import AppKit
import MaryBrain
import SwiftUI
import UniformTypeIdentifiers

extension AbilityStudioActionsEditor {

    func applicationIdentity(_ plugin: PluginSchema) -> some View {
        AbilityStudioEditorSection("1. Exact application", symbol: "app.badge.checkmark") {
            Text("Bundle identity selects the process. Titles and aliases help routing, but never authorize a different application.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Menu("Use Running Application") {
                    ForEach(runningApplications, id: \.bundleID) { application in
                        Button(application.title) {
                            applyApplication(
                                title: application.title,
                                bundleID: application.bundleID,
                                bundleName: "\(application.title).app",
                                shortVersion: application.shortVersion,
                                bundleVersion: application.bundleVersion)
                        }
                    }
                }
                Button("Choose .app…", action: chooseApplication)
                Spacer()
                Label(
                    plugin.application.activation == .requireFrontmost
                        ? "Must already be frontmost" : "May activate if already running",
                    systemImage: "macwindow.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                AbilityStudioTextField(
                    "Application title",
                    path: "plugin.application.title",
                    text: draftBinding(plugin.application.title, model: model) { draft, value in
                        draft.plugin?.application.title = value
                        draft.plugin?.title = value
                    })
                Picker("Activation", selection: draftBinding(
                    plugin.application.activation,
                    model: model) { $0.plugin?.application.activation = $1 }) {
                    ForEach(PluginApplicationActivation.allCases, id: \.self) {
                        Text($0 == .requireFrontmost ? "Require frontmost" : "Activate running").tag($0)
                    }
                }
                .frame(maxWidth: 230)
            }
            AbilityStudioTagEditor(
                title: "Bundle identifiers",
                path: "plugin.application.bundleIdentifiers",
                values: plugin.application.bundleIdentifiers) { values in
                model.mutateDraftPackage {
                    $0.plugin?.application.bundleIdentifiers = values
                }
            }
            AbilityStudioTagEditor(
                title: "Bundle names",
                path: "plugin.application.bundleNames",
                values: plugin.application.bundleNames) { values in
                model.mutateDraftPackage { $0.plugin?.application.bundleNames = values }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Verified application releases")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button("Add Release") {
                        model.mutateValidatedEditorPackage {
                            $0.plugin?.application.supportedReleases
                                .append(.init(
                                    shortVersion: "replace-short-version",
                                    bundleVersion: "replace-bundle-version"))
                        }
                    }
                    .disabled(plugin.application.supportedReleases.count >= 32)
                }
                Text("Each tuple records one exact CFBundleShortVersionString + CFBundleVersion pair this Ability was built and verified against. Ability Explorer shows an unmatched running build as not verified, but the comparison never blocks target resolution or command execution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(
                    Array(plugin.application.supportedReleases.enumerated()),
                    id: \.offset
                ) { index, release in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        AbilityStudioTextField(
                            "Short version",
                            path: "plugin.application.supportedReleases[\(index)].shortVersion",
                            text: Binding(
                                get: { release.shortVersion },
                                set: { value in
                                    model.mutateValidatedEditorPackage {
                                        $0.plugin?.application
                                            .supportedReleases[index]
                                            .shortVersion = value
                                    }
                                }),
                            monospaced: true)
                        AbilityStudioTextField(
                            "Bundle version",
                            path: "plugin.application.supportedReleases[\(index)].bundleVersion",
                            text: Binding(
                                get: { release.bundleVersion },
                                set: { value in
                                    model.mutateValidatedEditorPackage {
                                        $0.plugin?.application
                                            .supportedReleases[index]
                                            .bundleVersion = value
                                    }
                                }),
                            monospaced: true)
                        Button("Remove", role: .destructive) {
                            model.mutateValidatedEditorPackage {
                                $0.plugin?.application
                                    .supportedReleases.remove(at: index)
                            }
                        }
                    }
                }
                // No last-release guard; excluded lanes never make it fire.
                AbilityStudioSchemaPath(
                    "plugin.application.supportedReleases")
            }
            AbilityStudioTagEditor(
                title: "Aliases",
                path: "plugin.application.aliases",
                values: plugin.application.aliases) { values in
                model.mutateDraftPackage { $0.plugin?.application.aliases = values }
            }
            AbilityStudioTagEditor(
                title: "Target classes",
                path: "plugin.application.targetClasses",
                values: plugin.application.targetClasses) { values in
                model.mutateValidatedEditorPackage {
                    try AbilityStudioEditorIntegrity.replacePluginTargetClasses(
                        in: &$0,
                        with: values)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Content rectangle insets").font(.caption.weight(.medium))
                Text("Trim fixed chrome in window points. Pointer steps remain normalized from (0,0) to (1,1) inside the result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    insetField("Top", value: plugin.application.contentInsets.top) {
                        $0.plugin?.application.contentInsets.top = $1
                    }
                    insetField("Leading", value: plugin.application.contentInsets.leading) {
                        $0.plugin?.application.contentInsets.leading = $1
                    }
                    insetField("Bottom", value: plugin.application.contentInsets.bottom) {
                        $0.plugin?.application.contentInsets.bottom = $1
                    }
                    insetField("Trailing", value: plugin.application.contentInsets.trailing) {
                        $0.plugin?.application.contentInsets.trailing = $1
                    }
                }
                AbilityStudioSchemaPath("plugin.application.contentInsets")
            }

            Toggle(isOn: Binding(
                get: { plugin.application.perception != nil },
                set: { enabled in
                    model.mutateDraftPackage {
                        $0.plugin?.application.perception = enabled
                            ? .init(kind: .perceptionOnly) : nil
                    }
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Mary's generic Accessibility perception")
                    Text("Marker only. The package cannot schedule a poll or supply a reader.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            AbilityStudioSchemaPath("plugin.application.perception")
        }
    }

    func nativeFaculty(_ plugin: PluginSchema) -> some View {
        let adapters = Array(plugin.adapters.enumerated()).filter {
            $0.element.engine == .macUI
        }
        return AbilityStudioEditorSection("2. Native faculty", symbol: "checkmark.shield.fill") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("macUI · compiled into Mary").font(.headline)
                    Text("Closed key chords, bounded printable text, normalized pointer movement and gestures, scrolling, focused-window rebinds, cleanup, and waits. No source code, commands, executables, control-bearing text, or author-defined output.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(adapters.enumerated()), id: \.offset) { ordinal, indexed in
                let index = indexed.offset
                let adapter = indexed.element
                AbilityStudioBlockCard(number: ordinal + 1, title: adapter.title, symbol: "hand.point.up.left.fill") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        AbilityStudioTextField(
                            "Adapter id",
                            path: "plugin.adapters[\(index)].id",
                            text: draftBinding(adapter.id.rawValue, model: model) { draft, value in
                                let previous = adapter.id
                                let next = AdapterID(value)
                                draft.plugin?.adapters[index].id = next
                                if var operations = draft.plugin?.operations {
                                    for operationIndex in operations.indices
                                    where operations[operationIndex].adapterID == previous {
                                        operations[operationIndex].adapterID = next
                                    }
                                    draft.plugin?.operations = operations
                                }
                                for skillIndex in draft.skills.indices {
                                    for bindingIndex in draft.skills[skillIndex].execution.bindings.indices
                                    where draft.skills[skillIndex].execution.bindings[bindingIndex].adapterID == previous {
                                        draft.skills[skillIndex].execution.bindings[bindingIndex].adapterID = next
                                    }
                                }
                            },
                            monospaced: true)
                        AbilityStudioTextField(
                            "Title",
                            path: "plugin.adapters[\(index)].title",
                            text: draftBinding(adapter.title, model: model) {
                                $0.plugin?.adapters[index].title = $1
                            })
                    }
                    HStack {
                        Label(adapter.engine.rawValue, systemImage: "apple.logo")
                        Label("Accessibility", systemImage: "person.crop.circle.badge.checkmark")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if adapters.isEmpty {
                Button("Add macUI Adapter") {
                    model.mutateDraftPackage { draft in
                        guard let id = draft.plugin?.id else { return }
                        draft.plugin?.adapters.append(.init(
                            id: AdapterID("\(id).managed-ui"),
                            title: "Native UI"))
                    }
                }
            }
        }
    }

    func operations(_ plugin: PluginSchema) -> some View {
        let coverage = AbilityStudioActionCoveragePresentation(
            package: package,
            snapshot: model.snapshot)
        let hasMacUIAdapter = plugin.adapters.contains { $0.engine == .macUI }
        let actionIndices = coverage.actionGroups.flatMap(\.actions).map(\.operationIndex)
        let displayedOperation = actionIndices.contains(selectedOperation)
            ? selectedOperation : actionIndices.first
        return AbilityStudioEditorSection("3. Callable action recipes", symbol: "square.stack.3d.up.fill") {
            Text("Each action is a small ordered stack of visible Remote Hands blocks and realizes exactly one routed Skill. These are ordinary callable actions—not the private templates used by the semantic-plan compiler.")
                .foregroundStyle(.secondary)

            actionCoverage(coverage)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(coverage.actionGroups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.kind.title.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(group.kind.explanation)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 5)
                        .padding(.horizontal, 3)

                        ForEach(group.actions) { action in
                            Button {
                                selectedOperation = action.operationIndex
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(action.title)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    Text(action.operation)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Label(action.semanticLabel, systemImage: "point.3.connected.trianglepath.dotted")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(action.semantics == nil ? Color.secondary : Color.indigo)
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(action.ownership.conciseLabel)
                                            .lineLimit(1)
                                        Spacer(minLength: 3)
                                        Text(action.cleanupBlockCount == 0
                                             ? "\(action.blockCount) blocks"
                                             : "\(action.blockCount) + \(action.cleanupBlockCount) cleanup")
                                    }
                                    .font(.system(size: 9))
                                    .foregroundStyle(ownershipColor(action.ownership))
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    displayedOperation == action.operationIndex
                                        ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider().padding(.vertical, 3)
                    Button("Add Local Action") {
                        addOperation(plugin)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasMacUIAdapter)
                    Button("Implement Portable Skill…") {
                        showsPortableSkillImplementation = true
                    }
                    .disabled(!hasMacUIAdapter || coverage.implementationOptions.isEmpty)
                    .help("Give a dependency-owned semantic Skill bounded Remote Hands in this application.")
                }
                .frame(width: 230)

                Divider()

                if let displayedOperation,
                   plugin.operations.indices.contains(displayedOperation) {
                    AbilityStudioOperationEditor(
                        model: model,
                        plugin: plugin,
                        operationIndex: displayedOperation,
                        onRemove: {
                            removeOperation(plugin.operations[displayedOperation].operation)
                            selectedOperation = max(0, displayedOperation - 1)
                        })
                } else {
                    ContentUnavailableView(
                        "No actions yet",
                        systemImage: "square.stack.3d.up",
                        description: Text("Add a bounded recipe to teach this application."))
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
        }
    }

}

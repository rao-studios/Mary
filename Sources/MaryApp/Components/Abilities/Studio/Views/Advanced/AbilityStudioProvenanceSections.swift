//
//  AbilityStudioProvenanceSections.swift
//  Mary
//
//  WHAT: What this package depends on, who realizes it, and the raw source.
//  IN:   Advanced drawer.
//  OUT:  mutateDraftPackage; provider facts read the frozen registry.
//  PIN:  Provider is read-only — it reports what the runtime resolved, not what
//        the draft claims.
//

import MaryBrain
import SwiftUI

// MARK: - Dependencies

@MainActor
struct AbilityStudioDependenciesSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    private var pinned: Set<PackageID> {
        AbilityStudioEditorIntegrity.pinnedInstalledDependencyIDs(
            in: package,
            snapshot: model.snapshot)
    }

    var body: some View {
        StudioNote("Required means this ability realizes that one's meaning — it is what an expertise extends. Optional means it merely calls it when a route needs it.")

        ForEach(Array(package.dependencies.enumerated()), id: \.element.packageID) { index, dependency in
            let isPinned = pinned.contains(dependency.packageID)
            let installed = model.snapshot.package(id: dependency.packageID)
            HStack(spacing: .layer2) {
                Circle()
                    .fill(Color.maryAbilityTint(installed?.package.ability.tint ?? ""))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dependency.packageID.rawValue)
                        .font(.maryMono(10))
                        .foregroundStyle(Color.maryInk.opacity(0.8))
                    Text(installed == nil
                         ? "not installed"
                         : "\(dependency.minimumVersion.rawValue) or newer")
                        .font(.marySans(9))
                        .foregroundStyle(installed == nil
                                         ? Color.maryError
                                         : Color.maryInk.opacity(0.4))
                }
                Spacer(minLength: .layer1)
                if isPinned {
                    Image(systemName: "lock")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.maryInk.opacity(0.3))
                        .help("Provenance of an installed faculty; not this ability's to change.")
                } else {
                    MaryChip(
                        label: dependency.optional ? "optional" : "required",
                        isOn: !dependency.optional
                    ) {
                        model.mutateDraftPackage {
                            $0.dependencies[index].optional.toggle()
                        }
                    }
                    Button {
                        model.mutateDraftPackage { $0.dependencies.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.maryInk.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        addMenu
    }

    @ViewBuilder
    private var addMenu: some View {
        let options = model.snapshot.records.filter { record in
            record.id != package.package.id
                && !package.dependencies.contains { $0.packageID == record.id }
        }
        if !options.isEmpty {
            Menu {
                ForEach(options) { record in
                    Button(record.package.ability.title) {
                        model.mutateDraftPackage {
                            $0.dependencies.append(.init(
                                packageID: record.id,
                                minimumVersion: record.package.package.version,
                                optional: true))
                        }
                    }
                }
            } label: {
                Text("add a dependency…")
                    .font(.marySans(10))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - Provider & application

@MainActor
struct AbilityStudioProviderSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage

    var body: some View {
        if let record = model.selectedRecord {
            AbilityStudioFactLine(
                label: "Comes from",
                value: AbilityStudioLabels.provenance(record))
            AbilityStudioFactLine(
                label: "Version",
                value: package.package.version.rawValue)
            AbilityStudioFactLine(
                label: "Published by",
                value: package.package.publisher)
        }

        if let plugin = package.plugin {
            AbilityStudioFactLine(label: "Adapter", value: plugin.adapter.id.rawValue)
            AbilityStudioFactLine(
                label: "Actions",
                value: "\(plugin.operations.count) · realizing \(plugin.realizations.count) skills")
            if !plugin.application.targetClasses.isEmpty {
                AbilityStudioFactLine(
                    label: "Target class",
                    value: plugin.application.targetClasses.joined(separator: ", "))
            }
            surfaces(plugin)
        }

        ForEach(model.selectedProviderRealizations) { realization in
            HStack(spacing: .layer2) {
                Image(systemName: AbilityStudioLabels.providerSymbol(realization.provider.pluginClass))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.maryInk.opacity(0.45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(realization.provider.pluginTitle)
                        .font(.marySans(10))
                        .foregroundStyle(Color.maryInk.opacity(0.78))
                    Text("\(realization.activeSkillCount) of \(realization.realizedSkillCount) skills live")
                        .font(.marySans(9))
                        .foregroundStyle(Color.maryInk.opacity(0.4))
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(realization.isAvailable ? Color.maryGreen : Paper.graphite)
                    .frame(width: 6, height: 6)
                    .help(realization.unavailableReason ?? "available")
            }
        }
    }

    /// Surfaces are coordinates for faculties compiled into Mary. Authoring one
    /// here would imply an adapter the Studio cannot write.
    @ViewBuilder
    private func surfaces(_ plugin: PluginSchema) -> some View {
        let declared = [
            plugin.proseSurface != nil ? "prose" : nil,
            plugin.codeSurface != nil ? "code" : nil,
            plugin.mediaSurface != nil ? "media" : nil,
        ].compactMap { $0 }
        if !declared.isEmpty {
            AbilityStudioFactLine(
                label: "Surfaces",
                value: declared.joined(separator: ", "))
            StudioNote("Surfaces tell a compiled Mary faculty where this application keeps things. They are declared alongside the recipes that use them, not edited here.")
        }
    }
}

// MARK: - Raw schema

@MainActor
struct AbilityStudioSchemaSection: View {
    @ObservedObject var model: AbilityStudioViewModel

    var body: some View {
        if model.isLocalDraft {
            StudioNote("This package is not yours to change in place. Saving writes a local copy that shadows it.")
        }
        TextEditor(text: Binding(
            get: { model.draft },
            set: { model.updateDraft($0) }))
            .font(.maryMono(9.5))
            .foregroundStyle(Color.maryInk)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 220, maxHeight: 360)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.maryCard))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.maryBorder, lineWidth: 1))
        StudioNote("The canonical .mary source these controls write. Anything a card does not reach is reachable here.")
    }
}

// MARK: - Recipe step

@MainActor
struct AbilityStudioRecipeStepSection: View {
    @ObservedObject var model: AbilityStudioViewModel
    let recipe: SkillSchema

    private var step: WorkflowStepSchema? {
        guard let id = model.expandedRecipeStepID else { return nil }
        return recipe.execution.steps.first { $0.id == id }
    }

    var body: some View {
        if let step {
            AbilityStudioDeclarationCard(identifier: step.id) {
                AbilityStudioFactLine(label: "Calls", value: step.operation)
                StudioChipEditor("Takes", values: step.consumes) { next in
                    update { $0.consumes = next }
                }
                StudioChipEditor("Leaves", values: step.produces) { next in
                    update { $0.produces = next }
                }
                transition("On success", current: step.onSuccess) { next in
                    update { $0.onSuccess = next }
                }
                transition("On failure", current: step.onFailure) { next in
                    update { $0.onFailure = next }
                }
            }
            StudioNote("A step with no success transition simply runs the next one, which is why row order alone drives an ordinary recipe.")
        } else {
            StudioNote("Expand a recipe row to edit what it takes, what it leaves behind, and where it goes next.")
        }
    }

    private func transition(
        _ label: String,
        current: String?,
        set: @escaping (String?) -> Void
    ) -> some View {
        let others = recipe.execution.steps.map(\.id).filter { $0 != model.expandedRecipeStepID }
        return HStack(spacing: .layer2) {
            Text(label)
                .font(.marySans(9.5))
                .foregroundStyle(Color.maryInk.opacity(0.45))
                .frame(width: 74, alignment: .leading)
            Menu {
                Button("the next step") { set(nil) }
                ForEach(others, id: \.self) { id in
                    Button(id) { set(id) }
                }
            } label: {
                Text(current ?? "the next step")
                    .font(.maryMono(9.5))
                    .foregroundStyle(Color.maryInk.opacity(0.75))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: 200, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func update(_ transform: @escaping (inout WorkflowStepSchema) -> Void) {
        guard let id = model.expandedRecipeStepID else { return }
        model.mutateAuthoringDocument { document in
            try document.updateWorkflowStep(id, in: recipe.id, transform)
        }
    }
}

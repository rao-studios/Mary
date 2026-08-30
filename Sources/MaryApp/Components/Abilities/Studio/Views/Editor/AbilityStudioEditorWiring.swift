import MaryBrain
import SwiftUI

// MARK: - Wiring stage

@MainActor
struct AbilityStudioWiringEditor: View {
    @ObservedObject var model: AbilityStudioViewModel
    let package: MaryAbilityPackage
    @State private var selectedSkill = 0

    var body: some View {
        AbilityStudioStageScroll(
            title: "Connect meaning to implementation",
            introduction: "Skills say what Mary knows how to do. Capabilities constrain the effect. A realization or installed-faculty binding supplies the hands. These remain separate so one portable Skill can have several honest application providers.") {
            if let plugin = package.plugin {
                realizationEditor(plugin)
            }
            skillEditor
            capabilityEditor
            valueTypeEditor
            dependencyEditor
            projectionEditor
            fixtureEditor
        }
    }

    // MARK: Operation -> Skill

    private func realizationEditor(_ plugin: PluginSchema) -> some View {
        AbilityStudioEditorSection("Operation → Skill realizations", symbol: "arrow.right.square") {
            Text("A concrete application action realizes a provider-neutral Skill without putting an application identifier into the portable discipline.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Mappings are created atomically by Add Local Action or Implement Portable Skill in Remote Hands. This view inspects the result and tunes provider preference and target scope.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(plugin.operations.enumerated()), id: \.offset) { operationIndex, operation in
                let realizationIndex = plugin.realizations.firstIndex {
                    $0.operation == operation.operation
                }
                let realization = realizationIndex.map { plugin.realizations[$0] }
                let realizedSkill = realization.flatMap { realization in
                    model.snapshot.skills.first { $0.skill.id == realization.skillID }
                }
                AbilityStudioBlockCard(
                    number: operationIndex + 1,
                    title: operation.title,
                    symbol: "arrow.right") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(operation.operation).font(.caption.monospaced())
                            Text("Native action").font(.caption2).foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            if let realizedSkill {
                                Text("\(realizedSkill.ability.title) · \(realizedSkill.skill.title)")
                                    .font(.callout.weight(.medium))
                                Text(realizedSkill.skill.id.rawValue)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            } else if let realization {
                                Label(realization.skillID.rawValue, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.orange)
                                Text("The owning Skill is not installed.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("Not wired", systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.orange)
                                Text("Create this mapping from Remote Hands so compatibility is checked first.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let realization, let realizationIndex {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            AbilityStudioIntegerField(
                                "Preference",
                                path: "plugin.realizations[\(realizationIndex)].preference",
                                value: realization.preference) { value in
                                model.mutateDraftPackage {
                                    $0.plugin?.realizations[realizationIndex].preference = value
                                }
                            }
                            AbilityStudioTagEditor(
                                title: "Target classes",
                                path: "plugin.realizations[\(realizationIndex)].targetClasses",
                                values: realization.targetClasses) { values in
                                model.mutateDraftPackage {
                                    $0.plugin?.realizations[realizationIndex].targetClasses = values
                                }
                            }
                        }
                    }
                }
            }
            if plugin.operations.isEmpty {
                Label("Add a Remote Hands action before wiring a realization.", systemImage: "arrow.left")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Skills

    private var skillEditor: some View {
        AbilityStudioEditorSection(
            "Skills declared by \(package.ability.title)",
            symbol: "bolt.horizontal.fill"
        ) {
            Text("This list contains contracts owned by this package. Portable Skills implemented for a dependency remain owned by that dependency and appear in Operation → Skill realizations above instead of being copied here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(package.skills.enumerated()), id: \.offset) { index, skill in
                        Button {
                            selectedSkill = index
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.title).font(.callout.weight(.semibold)).lineLimit(1)
                                Text(skill.id.rawValue)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(skill.kind.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedSkill == index ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Add Skill", action: addSkill)
                        .buttonStyle(.borderedProminent)
                }
                .frame(width: 175)

                Divider()

                if package.skills.indices.contains(selectedSkill) {
                    AbilityStudioSkillCard(
                        model: model,
                        package: package,
                        skillIndex: selectedSkill,
                        onRemove: {
                            removeSkill(at: selectedSkill)
                            selectedSkill = max(0, selectedSkill - 1)
                        })
                } else {
                    ContentUnavailableView(
                        "No Skills",
                        systemImage: "bolt.horizontal",
                        description: Text("Add one semantic instruction to begin."))
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
        }
    }

    private func addSkill() {
        model.mutateDraftPackage { draft in
            let packageID = draft.package.id.rawValue
            let skillIDs = Set(draft.skills.map(\.id.rawValue))
            let capabilityIDs = Set(draft.capabilities.map(\.id.rawValue))
            let number = abilityStudioFirstUnusedSuffix { suffix in
                skillIDs.contains("\(packageID).skill-\(suffix)")
                    || capabilityIDs.contains("\(packageID).capability-\(suffix)")
            }
            let skillID = SkillID("\(draft.package.id.rawValue).skill-\(number)")
            let capabilityID = CapabilityID("\(draft.package.id.rawValue).capability-\(number)")
            let targetClass = draft.plugin?.application.targetClasses.first
                ?? "\(draft.package.id.rawValue)-target"
            draft.capabilities.append(.init(
                id: capabilityID,
                version: draft.package.version,
                title: "New Capability",
                summary: "Describe the bounded effect this Skill requires.",
                effect: .reversibleMutation,
                constraints: [
                    .init(kind: .requiresStage, value: "true"),
                    .init(kind: .allowedTargetClass, value: targetClass),
                ]))
            draft.skills.append(.init(
                id: skillID,
                version: draft.package.version,
                title: "New Skill",
                summary: "Describe one granular thing Mary knows how to do.",
                kind: .effectful,
                access: .reversible,
                requirements: .init(capabilities: [capabilityID]),
                routing: .init(eligibility: .init(kind: .targetClass, value: targetClass)),
                execution: .init(kind: .binding, realizationPolicy: .pluginRealizations),
                modelExposure: .init(
                    invocationName: skillID.rawValue
                        .replacingOccurrences(of: ".", with: "_")
                        .replacingOccurrences(of: "-", with: "_")),
                usesStage: true,
                timeoutSeconds: 10))
            draft.ability.skills.append(skillID)
        }
        selectedSkill = package.skills.count
    }

    private func removeSkill(at index: Int) {
        guard package.skills.indices.contains(index) else { return }
        let id = package.skills[index].id
        model.mutateAuthoringDocument {
            try $0.removeSkill(id)
        }
    }

    // MARK: Capabilities

    private var capabilityEditor: some View {
        AbilityStudioEditorSection("Capability contracts", symbol: "lock.shield") {
            Text("Capabilities are executable policy: effect class, permission reasons, target limits, confirmation, stage ownership, and payload bounds.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(Array(package.capabilities.enumerated()), id: \.offset) { index, capability in
                AbilityStudioCapabilityCard(
                    model: model,
                    package: package,
                    capability: capability,
                    index: index)
            }
            Button("Add Capability") {
                model.mutateDraftPackage { draft in
                    let id = abilityStudioFirstUnusedName(
                        stem: "\(draft.package.id.rawValue).capability",
                        existing: draft.capabilities.map { $0.id.rawValue })
                    draft.capabilities.append(.init(
                        id: CapabilityID(id),
                        version: draft.package.version,
                        title: "New Capability",
                        summary: "Describe this bounded effect.",
                        effect: .none))
                }
            }
        }
    }

    // MARK: Values

    private var valueTypeEditor: some View {
        AbilityStudioEditorSection("Value types", symbol: "cube.transparent") {
            Text("Typed values connect Skill ports and installed faculty contracts. Imported prose never substitutes for this shape graph.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(Array(package.valueTypes.enumerated()), id: \.offset) { index, valueType in
                AbilityStudioValueTypeCard(
                    model: model,
                    package: package,
                    valueType: valueType,
                    index: index)
            }
            Button("Add Value Type") {
                model.mutateDraftPackage { draft in
                    let id = abilityStudioFirstUnusedName(
                        stem: "\(draft.package.id.rawValue).value",
                        existing: draft.valueTypes.map { $0.id.rawValue })
                    draft.valueTypes.append(.init(
                        id: ValueTypeID(id),
                        version: draft.package.version,
                        title: "New Value",
                        summary: "Describe this typed value.",
                        shape: .string))
                }
            }
        }
    }

    // MARK: Dependencies and projections

    private var dependencyEditor: some View {
        AbilityStudioEditorSection("Dependencies", symbol: "link") {
            Text("External Skill and schema references require an explicit package dependency. Choosing an external realization adds its owner automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(package.dependencies.enumerated()), id: \.offset) { index, dependency in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if pinnedInstalledDependencyIDs.contains(dependency.packageID) {
                        LabeledContent("Package") {
                            Text(dependency.packageID.rawValue)
                                .font(.body.monospaced())
                        }
                        LabeledContent("Minimum version") {
                            Text(dependency.minimumVersion.rawValue)
                                .font(.body.monospaced())
                        }
                        Label("Required provenance", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        AbilityStudioTextField(
                            "Package",
                            path: "dependencies[\(index)].packageID",
                            text: Binding(
                                get: { dependency.packageID.rawValue },
                                set: { value in
                                    model.mutateDraftPackage {
                                        $0.dependencies[index].packageID = PackageID(value)
                                    }
                                }),
                            monospaced: true)
                        AbilityStudioTextField(
                            "Minimum version",
                            path: "dependencies[\(index)].minimumVersion",
                            text: Binding(
                                get: { dependency.minimumVersion.rawValue },
                                set: { value in
                                    model.mutateDraftPackage {
                                        $0.dependencies[index].minimumVersion = SemanticVersion(value)
                                    }
                                }),
                            monospaced: true)
                        Toggle("Optional", isOn: Binding(
                            get: { dependency.optional },
                            set: { value in
                                model.mutateDraftPackage { $0.dependencies[index].optional = value }
                            }))
                        Button {
                            model.mutateDraftPackage { $0.dependencies.remove(at: index) }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
            }
            Menu("Add Installed Package") {
                ForEach(model.snapshot.records.filter { record in
                    record.id != package.package.id
                        && !package.dependencies.contains(where: { dependency in
                            dependency.packageID == record.id
                        })
                }) { record in
                    Button(record.package.ability.title) {
                        model.mutateDraftPackage {
                            $0.dependencies.append(.init(
                                packageID: record.id,
                                minimumVersion: record.package.package.version))
                        }
                    }
                }
            }
        }
    }

    private var pinnedInstalledDependencyIDs: Set<PackageID> {
        AbilityStudioEditorIntegrity.pinnedInstalledDependencyIDs(
            in: package,
            snapshot: model.snapshot)
    }

    private var projectionEditor: some View {
        AbilityStudioEditorSection("Totem projections", symbol: "archivebox") {
            Text("Nothing persists by default. A projection is the explicit, Skill-scoped exception.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(package.totemProjections.enumerated()), id: \.offset) { index, projection in
                AbilityStudioProjectionCard(
                    model: model,
                    package: package,
                    projection: projection,
                    index: index)
            }
            Button("Add Receipt Projection") {
                model.mutateDraftPackage { draft in
                    let rawID = abilityStudioFirstUnusedName(
                        stem: "\(draft.package.id.rawValue).receipts",
                        existing: draft.totemProjections.map { $0.id.rawValue })
                    let id = ProjectionID(rawID)
                    draft.totemProjections.append(.init(
                        id: id,
                        version: draft.package.version,
                        purpose: .receipt,
                        skills: [],
                        persistence: .session,
                        redactContent: true))
                    draft.ability.totemProjections.append(id)
                }
            }
        }
    }

    private var fixtureEditor: some View {
        AbilityStudioEditorSection("Routing test fixtures", symbol: "checkmark.seal") {
            Text("Keep a few plain-language examples with the Ability so routing intent can be checked before activation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(package.fixtures.enumerated()), id: \.offset) { index, fixture in
                AbilityStudioFixtureCard(
                    model: model,
                    package: package,
                    fixture: fixture,
                    index: index)
            }
            Button("Add Test Example") {
                model.mutateDraftPackage { draft in
                    let id = abilityStudioFirstUnusedName(
                        stem: "routing-example",
                        existing: draft.fixtures.map(\.id))
                    draft.fixtures.append(.init(
                        id: id,
                        utterance: "Describe something a person might ask.",
                        expectedSkill: draft.skills.first?.id,
                        targetClass: draft.plugin?.application.targetClasses.first,
                        expectedDisposition: draft.skills.isEmpty ? "abstain" : "route"))
                }
            }
        }
    }
}

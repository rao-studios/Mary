import MaryBrain
import Foundation

/// Visual-editor view of a package-owned macUI provider. Local vs portable Skills stay separate.
struct AbilityStudioActionCoveragePresentation {
    enum ActionOwnership: Hashable {
        case local(skillID: SkillID, title: String)
        case portable(
            packageID: PackageID,
            packageTitle: String,
            skillID: SkillID,
            skillTitle: String)
        case unresolved(skillID: SkillID?)

        var group: ActionGroup.Kind {
            switch self {
            case .local: return .local
            case .portable: return .portable
            case .unresolved: return .unresolved
            }
        }

        var conciseLabel: String {
            switch self {
            case .local(_, let title):
                return "Local · \(title)"
            case .portable(_, let packageTitle, _, let skillTitle):
                return "\(packageTitle) · \(skillTitle)"
            case .unresolved(let skillID):
                return skillID.map { "Unresolved · \($0.rawValue)" }
                    ?? "Not wired"
            }
        }
    }

    struct Action: Hashable, Identifiable {
        let operationIndex: Int
        let operation: String
        let title: String
        let blockCount: Int
        let cleanupBlockCount: Int
        let ownership: ActionOwnership
        let semantics: PluginOperationSemantics?

        var id: String { operation }

        var semanticLabel: String {
            guard let semantics else { return "role unspecified" }
            switch semantics.role {
            case .utility:
                return "utility"
            case .observe:
                return "observe"
            case .createArtifact:
                return "create · \(semantics.aliases.joined(separator: ", "))"
            case .mutateArtifact:
                return "mutate"
            }
        }
    }

    struct ActionGroup: Hashable, Identifiable {
        enum Kind: String, Hashable {
            case local
            case portable
            case unresolved

            var title: String {
                switch self {
                case .local: return "Actions declared here"
                case .portable: return "Portable Skill implementations"
                case .unresolved: return "Needs wiring"
                }
            }

            var explanation: String {
                switch self {
                case .local:
                    return "Callable Skills owned by this package"
                case .portable:
                    return "Native hands for dependency-owned meaning"
                case .unresolved:
                    return "Recipes without one resolvable semantic owner"
                }
            }
        }

        let kind: Kind
        let actions: [Action]

        var id: Kind { kind }
    }

    enum Starter: Hashable {
        case keyChord
        case boundedVerification
    }

    enum Compatibility: Hashable {
        case compatible(starter: Starter, targetClasses: [String])
        case needsRuntimeFaculty(reason: String)

        var canImplement: Bool {
            if case .compatible = self { return true }
            return false
        }

        var reason: String? {
            guard case .needsRuntimeFaculty(let reason) = self else { return nil }
            return reason
        }

        var targetClasses: [String] {
            guard case .compatible(_, let targetClasses) = self else { return [] }
            return targetClasses
        }

        var starter: Starter? {
            guard case .compatible(let starter, _) = self else { return nil }
            return starter
        }
    }

    struct PortableSkillOption: Hashable, Identifiable {
        let ownerPackageID: PackageID
        let ownerTitle: String
        let skillID: SkillID
        let skillTitle: String
        let summary: String
        let isDeclaredDependency: Bool
        let compatibility: Compatibility

        var id: String {
            "\(ownerPackageID.rawValue)/\(skillID.rawValue)"
        }
    }

    let remoteHandsActionCount: Int
    let localSkillCount: Int
    let dependencyImplementationCount: Int
    let missingDependencySkills: [PortableSkillOption]
    let implementationOptions: [PortableSkillOption]
    let actionGroups: [ActionGroup]

    var missingDependencySkillCount: Int { missingDependencySkills.count }

    init(
        package: MaryAbilityPackage,
        snapshot: AbilityRuntimeSnapshot
    ) {
        let plugin = package.plugin
        let localSkills = Dictionary(
            package.skills.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let records = snapshot.records.map(\.package).filter {
            $0.package.id != package.package.id
        }
        let packages = records + [package]
        let skillOwners = Self.skillOwners(in: packages)
        let dependencyIDs = Set(package.dependencies.map(\.packageID))
        let realizationsByOperation = Dictionary(
            (plugin?.realizations ?? []).map { ($0.operation, $0) },
            uniquingKeysWith: { first, _ in first })

        let actions: [Action] = (plugin?.operations ?? []).enumerated().compactMap {
            index, operation -> Action? in
            guard plugin?.adapter(for: operation)?.engine == .macUI else {
                return nil
            }
            let realization = realizationsByOperation[operation.operation]
            let ownership: ActionOwnership
            if let skillID = realization?.skillID,
               let skill = localSkills[skillID] {
                ownership = .local(skillID: skillID, title: skill.title)
            } else if let skillID = realization?.skillID,
                      let owner = skillOwners[skillID] {
                ownership = .portable(
                    packageID: owner.package.package.id,
                    packageTitle: owner.package.ability.title,
                    skillID: skillID,
                    skillTitle: owner.skill.title)
            } else {
                ownership = .unresolved(skillID: realization?.skillID)
            }
            return Action(
                operationIndex: index,
                operation: operation.operation,
                title: operation.title,
                blockCount: operation.steps.count,
                cleanupBlockCount: operation.cleanupSteps.count,
                ownership: ownership,
                semantics: operation.semantics)
        }

        let grouped: [ActionGroup.Kind: [Action]] = Dictionary(
            grouping: actions,
            by: { $0.ownership.group })
        let groups: [ActionGroup] = grouped.map { kind, groupedActions in
            ActionGroup(
                kind: kind,
                actions: groupedActions.sorted {
                    $0.operationIndex < $1.operationIndex
                })
        }
        actionGroups = groups.sorted {
            ($0.actions.map(\.operationIndex).min() ?? .max)
                < ($1.actions.map(\.operationIndex).min() ?? .max)
        }

        remoteHandsActionCount = actions.count
        localSkillCount = package.skills.count
        dependencyImplementationCount = actions.filter { action in
            guard case .portable(let packageID, _, _, _) = action.ownership else {
                return false
            }
            return dependencyIDs.contains(packageID)
        }.count

        let realizedSkillIDs = Set((plugin?.realizations ?? []).map(\.skillID))
        let capabilities = Dictionary(
            packages.flatMap(\.capabilities).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        implementationOptions = records.flatMap { owner in
            owner.skills.compactMap { skill -> PortableSkillOption? in
                guard skill.execution.kind == .binding,
                      skill.execution.realizationPolicy == .pluginRealizations,
                      !realizedSkillIDs.contains(skill.id)
                else { return nil }
                return PortableSkillOption(
                    ownerPackageID: owner.package.id,
                    ownerTitle: owner.ability.title,
                    skillID: skill.id,
                    skillTitle: skill.title,
                    summary: skill.summary,
                    isDeclaredDependency: dependencyIDs.contains(owner.package.id),
                    compatibility: Self.compatibility(
                        for: skill,
                        capabilities: capabilities))
            }
        }.sorted(by: Self.optionOrder)
        missingDependencySkills = implementationOptions.filter(\.isDeclaredDependency)
    }

    private static func skillOwners(
        in packages: [MaryAbilityPackage]
    ) -> [SkillID: (package: MaryAbilityPackage, skill: SkillSchema)] {
        Dictionary(
            packages.flatMap { package in
                package.skills.map { ($0.id, (package, $0)) }
            },
            uniquingKeysWith: { first, _ in first })
    }

    private static func compatibility(
        for skill: SkillSchema,
        capabilities: [CapabilityID: CapabilitySchema]
    ) -> Compatibility {
        var needs: [String] = []

        if !skill.usesStage {
            needs.append("full-stage native authorization")
        }
        if !skill.inputs.isEmpty {
            needs.append("typed Skill inputs")
        }
        if !skill.outputs.isEmpty {
            needs.append("typed native outputs")
        }
        if !skill.requirements.interactions.isEmpty {
            needs.append("source-owned interaction consumption")
        }
        if !skill.requirements.perceptions.isEmpty {
            needs.append("typed native perception")
        }
        if !skill.modelExposure.parameters.isEmpty {
            let names = skill.modelExposure.parameters.prefix(3).map(\.name)
            let suffix = skill.modelExposure.parameters.count > names.count ? ", …" : ""
            needs.append("semantic parameter handling (\(names.joined(separator: ", "))\(suffix))")
        }

        let requiredCapabilities = skill.requirements.capabilities.compactMap {
            capabilities[$0]
        }
        if requiredCapabilities.count != skill.requirements.capabilities.count {
            needs.append("a resolvable Capability contract")
        }
        let hasStageCapability = requiredCapabilities.contains { capability in
            capability.constraints.contains {
                $0.kind == .requiresStage && $0.value == "true"
            }
        }
        if !hasStageCapability {
            needs.append("a stage-owning Capability")
        }

        let targetSets = requiredCapabilities.compactMap { capability -> Set<String>? in
            let targets = Set(capability.constraints.compactMap {
                $0.kind == .allowedTargetClass ? $0.value : nil
            })
            return targets.isEmpty ? nil : targets
        }
        let allowedTargets = targetSets.isEmpty
            ? Set<String>()
            : targetSets.dropFirst().reduce(targetSets[0]) { $0.intersection($1) }
        if allowedTargets.isEmpty {
            needs.append("an allowed target-class contract")
        }

        if !needs.isEmpty {
            return .needsRuntimeFaculty(
                reason: "Needs a Mary-owned faculty for \(needs.joined(separator: ", ")).")
        }

        let hasMutationAuthority = requiredCapabilities.contains { capability in
            switch capability.effect {
            case .reversibleMutation, .mutation, .destructive, .externalCommunication:
                return true
            case .none, .read:
                return false
            }
        }
        return .compatible(
            starter: hasMutationAuthority ? .keyChord : .boundedVerification,
            targetClasses: allowedTargets.sorted())
    }

    private static func optionOrder(
        _ left: PortableSkillOption,
        _ right: PortableSkillOption
    ) -> Bool {
        if left.isDeclaredDependency != right.isDeclaredDependency {
            return left.isDeclaredDependency && !right.isDeclaredDependency
        }
        if left.ownerTitle != right.ownerTitle {
            return left.ownerTitle.localizedStandardCompare(right.ownerTitle)
                == .orderedAscending
        }
        return left.skillTitle.localizedStandardCompare(right.skillTitle)
            == .orderedAscending
    }
}

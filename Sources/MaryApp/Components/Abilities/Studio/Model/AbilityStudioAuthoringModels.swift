//
//  AbilityStudioAuthoringModels.swift
//  Mary
//
//  WHAT: Authoring kinds, errors, templates, catalog palettes.
//  IN:   AbilityStudioAuthoring.swift (sibling split)
//  OUT:  AbilityStudioPackageFactory / AbilityStudioViewModel
//

import MaryBrain
import Foundation



/// Ways an external `.mary` document acquires hands.
/// Package-owned: bounded recipes for the compiled `macUI` interpreter.
/// Installed faculty: Skill bound to an operation a compiled adapter already publishes.
enum AbilityStudioAuthoringKind: String, CaseIterable, Sendable {
    case packageOwnedNativeApplication
    case installedFaculty
}

enum AbilityStudioAuthoringError: LocalizedError {
    case invalidPackageID(String)
    case invalidBundleIdentifier(String)
    case pluginRequired
    case macUIAdapterRequired
    case operationAlreadyExists(String)
    case operationNotFound(String)
    case skillAlreadyExists(SkillID)
    case skillNotFound(SkillID)
    case stepNotFound(String)
    case cannotRemoveLastRecipeStep(String)
    case cannotRemoveLastPluginOperation
    case installedOperationNotFound(adapterID: AdapterID, operation: String)
    case installedFacultyMustBeNative(AdapterID)
    case invalidMutation([SchemaIssue])
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPackageID(let value):
            return "\(value) is not a portable lower-case package identifier."
        case .invalidBundleIdentifier(let value):
            return "\(value) is not an exact reverse-DNS application bundle identifier."
        case .pluginRequired:
            return "This authoring operation requires a package-owned native application provider."
        case .macUIAdapterRequired:
            return "Add a macUI adapter before authoring a native interaction recipe."
        case .operationAlreadyExists(let operation):
            return "Plugin operation \(operation) already exists."
        case .operationNotFound(let operation):
            return "Plugin operation \(operation) does not exist."
        case .skillAlreadyExists(let skillID):
            return "Skill \(skillID.rawValue) already exists."
        case .skillNotFound(let skillID):
            return "Skill \(skillID.rawValue) does not exist."
        case .stepNotFound(let stepID):
            return "Recipe step \(stepID) does not exist."
        case .cannotRemoveLastRecipeStep(let operation):
            return "Plugin operation \(operation) must retain at least one recipe step."
        case .cannotRemoveLastPluginOperation:
            return "A package-owned native provider must retain at least one realized operation."
        case let .installedOperationNotFound(adapterID, operation):
            return "Installed adapter \(adapterID.rawValue) does not publish \(operation)."
        case .installedFacultyMustBeNative(let adapterID):
            return "\(adapterID.rawValue) is Ability-carried data, not an installed compiled faculty."
        case .invalidMutation(let issues):
            return issues.first?.message ?? "The edit would make the Ability graph invalid."
        case .encodingFailed:
            return "The Ability could not be encoded as canonical .mary JSON."
        }
    }
}

struct AbilityStudioNativeApplicationTemplate: Sendable {
    var packageID: PackageID
    var title: String
    var bundleIdentifier: String
    var bundleName: String?
    var publisher: String
    var tint: String

    init(
        packageID: PackageID,
        title: String,
        bundleIdentifier: String,
        bundleName: String? = nil,
        publisher: String = "local",
        tint: String = "#8888FF"
    ) {
        self.packageID = packageID
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.publisher = publisher
        self.tint = tint
    }
}

/// Derive a new Ability from a callable contract already joined to an installed faculty.
/// A manifest alone is insufficient: the source Skill owns the model-facing contract.
struct AbilityStudioInstalledFacultyTemplate: Sendable {
    var packageID: PackageID
    var title: String
    var summary: String
    var faculty: AbilityStudioInstalledFacultyOption
    var publisher: String
    var tint: String

    init(
        packageID: PackageID,
        title: String,
        summary: String,
        faculty: AbilityStudioInstalledFacultyOption,
        publisher: String = "local",
        tint: String = "#7C5CFF"
    ) {
        self.packageID = packageID
        self.title = title
        self.summary = summary
        self.faculty = faculty
        self.publisher = publisher
        self.tint = tint
    }
}

struct AbilityStudioInstalledFacultyOption: Hashable, Identifiable, Sendable {
    var manifest: InstalledAdapterManifest
    var operation: InstalledAdapterBinding
    var runtimeSkill: AbilityRuntimeSkill
    var sourcePackage: MaryAbilityPackage

    var id: String {
        [
            manifest.adapterID.rawValue,
            operation.operation,
            runtimeSkill.skill.id.rawValue,
        ].joined(separator: "/")
    }
}

enum AbilityStudioAuthoringCatalog {
    /// Palette for an installed-faculty package. Each option is joined to a validated runtime Skill.
    static func installedFaculties(
        in snapshot: AbilityRuntimeSnapshot
    ) -> [AbilityStudioInstalledFacultyOption] {
        let validRecords = Dictionary(
            snapshot.records.compactMap { record in
                record.validation.isValid
                    ? (record.package.package.id, record.package) : nil
            },
            uniquingKeysWith: { first, _ in first })
        var options: [AbilityStudioInstalledFacultyOption] = []
        for manifest in snapshot.adapterManifests
        where manifest.resolvedProvider.pluginClass == .runtime
            && manifest.isAvailable {
            for operation in manifest.operations
            where operation.isAvailable
                && !RuntimePrimitiveOperations.contains(operation.operation) {
                for runtimeSkill in snapshot.skills
                where runtimeSkill.availability.readiness == .ready
                    && runtimeSkill.availability.selectedBinding.map({
                        $0.adapterID == manifest.adapterID
                            && $0.operation == operation.operation
                    }) == true {
                    guard let sourcePackage = validRecords[runtimeSkill.packageID],
                          sourcePackage.skills.contains(where: { sourceSkill in
                              sourceSkill.id == runtimeSkill.skill.id
                                  && sourceSkill.execution.bindings.contains(where: {
                                      $0.adapterID == manifest.adapterID
                                          && $0.operation == operation.operation
                                  })
                          })
                    else { continue }
                    options.append(.init(
                        manifest: manifest,
                        operation: operation,
                        runtimeSkill: runtimeSkill,
                        sourcePackage: sourcePackage))
                }
            }
        }
        return options.sorted { lhs, rhs in
                let left = (
                    lhs.manifest.adapterID.rawValue,
                    lhs.operation.operation,
                    lhs.runtimeSkill.skill.id.rawValue)
                let right = (
                    rhs.manifest.adapterID.rawValue,
                    rhs.operation.operation,
                    rhs.runtimeSkill.skill.id.rawValue)
                if left.0 != right.0 { return left.0 < right.0 }
                if left.1 != right.1 { return left.1 < right.1 }
                return left.2 < right.2
            }
    }

    /// Realization palette for a package-owned Remote Hands provider. Graph validator still checks output.
    static func portableSkills(
        in snapshot: AbilityRuntimeSnapshot
    ) -> [AbilityRuntimeSkill] {
        snapshot.skills.filter {
            $0.skill.execution.kind == .binding
                && $0.skill.execution.realizationPolicy == .pluginRealizations
        }.sorted { $0.skill.id.rawValue < $1.skill.id.rawValue }
    }
}

enum AbilityStudioRecipeLane: Hashable, Sendable {
    case action
    case cleanup

    func steps(in operation: PluginOperationSchema) -> [PluginRecipeStepSchema] {
        switch self {
        case .action: return operation.steps
        case .cleanup: return operation.cleanupSteps
        }
    }
}

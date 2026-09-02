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
    case recipeNotFound(SkillID)
    case workflowStepNotFound(String)
    case cannotRemoveLastWorkflowStep(SkillID)
    case invalidInvocationName(String)
    case workflowIsBranching(SkillID)
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
        case .recipeNotFound(let skillID):
            return "Recipe \(skillID.rawValue) does not exist."
        case .workflowStepNotFound(let stepID):
            return "Recipe step \(stepID) does not exist."
        case .cannotRemoveLastWorkflowStep:
            return "A recipe must keep at least one step. Remove the recipe itself instead."
        case .invalidInvocationName(let value):
            return value.isEmpty
                ? "Name the skill this step should call."
                : "\(value) is not a callable skill name — use lower-case words joined by underscores."
        case .workflowIsBranching(let skillID):
            return "Recipe \(skillID.rawValue) has its own failure branches; reorder its steps in Advanced."
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
// The installed-faculty catalogue went with that authoring lane: the Studio
// teaches applications, and a discipline's faculties are compiled into Mary.

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

import MaryBrain
import Foundation

/// Visual mutations on a candidate; VM validates before replacing the draft.
enum AbilityStudioEditorIntegrity {
    enum MutationError: LocalizedError, Equatable {
        case applicationNotFound(String)
        case duplicateApplicationID(String)
        case pluginRequired
        case targetClassesRequired
        case skillNotFound(SkillID)
        case workflowKindIsSourceOnly
        case skillHasBindings(SkillID)
        case skillHasPluginRealization(SkillID)
        case skillHasWorkflowSteps(SkillID)
        case installedFacultyUnavailable(AdapterID, String)
        case installedFacultySourceMismatch(SkillID)
        case operationNotFound(String)
        case operationAlreadyExists(String)
        case inputNotFound(String)
        case inputAlreadyExists(String)
        case inputStillRequiredByRecipe(String)
        case noCompatibleRecipeExpression(String, PluginOperationInputKind)

        var errorDescription: String? {
            switch self {
            case .applicationNotFound(let id):
                return "Application \(id) is no longer present in this draft."
            case .duplicateApplicationID(let id):
                return "Application id \(id) is already in use."
            case .pluginRequired:
                return "This edit requires a package-owned native application faculty."
            case .targetClassesRequired:
                return "A visually-authored native application must keep at least one target class."
            case .skillNotFound(let id):
                return "Skill \(id.rawValue) is no longer present in this draft."
            case .workflowKindIsSourceOnly:
                return "Workflow execution is source-only until Ability Editor has a complete workflow-step editor."
            case .skillHasBindings(let id):
                return "Remove \(id.rawValue)'s installed-faculty bindings before changing it to a Cognitive Skill."
            case .skillHasPluginRealization(let id):
                return "Remove the Remote Hands action realizing \(id.rawValue) before changing it to a Cognitive Skill."
            case .skillHasWorkflowSteps(let id):
                return "Skill \(id.rawValue) owns workflow steps. Edit that execution shape in Advanced Schema."
            case .installedFacultyUnavailable(let adapterID, let operation):
                return "Installed faculty \(adapterID.rawValue)/\(operation) is not an available compiled provider."
            case .installedFacultySourceMismatch(let skillID):
                return "The installed faculty no longer supplies the complete contract for \(skillID.rawValue). Refresh the catalog and choose it again."
            case .operationNotFound(let operation):
                return "Native operation \(operation) is no longer present in this draft."
            case .operationAlreadyExists(let operation):
                return "Native operation \(operation) is already in use."
            case .inputNotFound(let input):
                return "Recipe input \(input) is no longer present in this action."
            case .inputAlreadyExists(let input):
                return "Recipe input \(input) is already in use."
            case .inputStillRequiredByRecipe(let input):
                return "Recipe input \(input) is still used without a fixed fallback. Give every use a fallback before removing it."
            case .noCompatibleRecipeExpression(let operation, let kind):
                return "Native operation \(operation) has no fixed \(kind.rawValue) expression to connect. Add a compatible recipe block first."
            }
        }
    }

}

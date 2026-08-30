import MaryBrain
import Foundation

/// Transactional visual edits; Schema tab may still hold an incomplete draft.
struct AbilityStudioAuthoringDocument: Sendable {
    internal(set) var package: MaryAbilityPackage
    var contextPackages: [MaryAbilityPackage]

    init(
        package: MaryAbilityPackage,
        contextPackages: [MaryAbilityPackage] = []
    ) {
        self.package = package
        self.contextPackages = contextPackages.filter {
            $0.package.id != package.package.id
        }
    }

    var kind: AbilityStudioAuthoringKind {
        if package.plugin != nil {
            return .packageOwnedNativeApplication
        }
        if package.skills.contains(where: {
            $0.execution.kind == .binding && !$0.execution.bindings.isEmpty
        }) {
            return .installedFaculty
        }
        // Studio currently offers two executable authoring lanes. A semantic
        // package without a package-owned provider belongs in the installed
        // faculty lane until the author chooses its compiled realization.
        return .installedFaculty
    }

    var validation: AbilityPackageValidation {
        AbilityPackageValidator.validateGraph(contextPackages + [package])
    }

    func canonicalData() throws -> Data {
        try AbilityPackageCodec.encoded(package)
    }

    func canonicalJSON() throws -> String {
        guard let value = String(data: try canonicalData(), encoding: .utf8) else {
            throw AbilityStudioAuthoringError.encodingFailed
        }
        return value
    }

    mutating func updateAbility(
        _ transform: (inout AbilitySchema) -> Void
    ) throws {
        try commit { transform(&$0.ability) }
    }

    // No artifact-domain mutations; schema has no artifactDomain.

    @discardableResult
    mutating func addRemoteHandsAction(
        title: String,
        summary: String,
        inputs: [PluginOperationInputSchema] = [],
        steps: [PluginRecipeStepSchema],
        cleanupSteps: [PluginRecipeStepSchema] = [],
        semantics: PluginOperationSemantics = .init(role: .utility),
        targetClasses: [String] = [],
        access: SkillAccess = .reversible,
        preference: Int = 100
    ) throws -> (skillID: SkillID, operation: String) {
        guard package.plugin != nil else {
            throw AbilityStudioAuthoringError.pluginRequired
        }
        let identity = nextActionIdentity(title: title)
        let skillID = SkillID("\(package.package.id.rawValue).\(identity.skillStem)")
        let capabilityID = CapabilityID("\(skillID.rawValue).execute")
        try commit { candidate in
            guard var plugin = candidate.plugin else {
                throw AbilityStudioAuthoringError.pluginRequired
            }
            guard let adapterID = plugin.adapters.first(where: {
                $0.engine == .macUI
            })?.id else {
                throw AbilityStudioAuthoringError.macUIAdapterRequired
            }
            let realizedTargets = targetClasses.isEmpty
                ? plugin.application.targetClasses
                : targetClasses
            let capability = CapabilitySchema(
                id: capabilityID,
                title: title,
                summary: summary,
                effect: access == .reversible ? .reversibleMutation : .mutation,
                constraints: AbilityStudioPackageFactory.nativeStageConstraints(
                    targetClasses: realizedTargets))
            let parameters = inputs.map(Self.modelParameter)
            let skill = SkillSchema(
                id: skillID,
                title: title,
                summary: summary,
                kind: .effectful,
                access: access,
                requirements: .init(capabilities: [capabilityID]),
                routing: .init(eligibility: realizedTargets.first.map {
                    .init(kind: .targetClass, value: $0)
                }),
                execution: .init(
                    kind: .binding,
                    realizationPolicy: .pluginRealizations),
                modelExposure: .init(
                    invocationName: identity.operation,
                    parameters: parameters,
                    inheritsBindingContract: true),
                usesStage: true,
                timeoutSeconds: 10)
            candidate.capabilities.append(capability)
            candidate.skills.append(skill)
            candidate.ability.skills.append(skillID)
            plugin.operations.append(.init(
                operation: identity.operation,
                title: title,
                summary: summary,
                adapterID: adapterID,
                semantics: semantics,
                inputs: inputs,
                steps: steps,
                cleanupSteps: cleanupSteps,
                postconditions: [
                    .applicationFrontmost,
                    .applicationWindowAvailable,
                ]))
            plugin.realizations.append(.init(
                skillID: skillID,
                operation: identity.operation,
                preference: preference,
                targetClasses: realizedTargets))
            for targetClass in realizedTargets
            where !plugin.application.targetClasses.contains(targetClass) {
                plugin.application.targetClasses.append(targetClass)
            }
            candidate.plugin = plugin
        }
        return (skillID, identity.operation)
    }

    @discardableResult
    mutating func addPluginOperation(
        operation requestedName: String? = nil,
        title: String,
        summary: String,
        inputs: [PluginOperationInputSchema] = [],
        steps: [PluginRecipeStepSchema],
        cleanupSteps: [PluginRecipeStepSchema] = [],
        semantics: PluginOperationSemantics = .init(role: .utility),
        realizing skillID: SkillID,
        ownerPackage: MaryAbilityPackage? = nil,
        preference: Int = 100,
        targetClasses: [String] = []
    ) throws -> String {
        guard let plugin = package.plugin else {
            throw AbilityStudioAuthoringError.pluginRequired
        }
        let generated = nextActionIdentity(title: title).operation
        let operation = requestedName ?? generated
        if plugin.operations.contains(where: { $0.operation == operation }) {
            throw AbilityStudioAuthoringError.operationAlreadyExists(operation)
        }
        try commit { candidate in
            guard var draftPlugin = candidate.plugin else {
                throw AbilityStudioAuthoringError.pluginRequired
            }
            guard let adapterID = draftPlugin.adapters.first(where: {
                $0.engine == .macUI
            })?.id else {
                throw AbilityStudioAuthoringError.macUIAdapterRequired
            }
            draftPlugin.operations.append(.init(
                operation: operation,
                title: title,
                summary: summary,
                adapterID: adapterID,
                semantics: semantics,
                inputs: inputs,
                steps: steps,
                cleanupSteps: cleanupSteps,
                postconditions: [
                    .applicationFrontmost,
                    .applicationWindowAvailable,
                ]))
            draftPlugin.realizations.append(.init(
                skillID: skillID,
                operation: operation,
                preference: preference,
                targetClasses: targetClasses))
            for targetClass in targetClasses
            where !draftPlugin.application.targetClasses.contains(targetClass) {
                draftPlugin.application.targetClasses.append(targetClass)
            }
            candidate.plugin = draftPlugin
            Self.ensureDependency(on: ownerPackage, in: &candidate)
        }
        return operation
    }

    mutating func updateOperation(
        _ operation: String,
        _ transform: (inout PluginOperationSchema) -> Void
    ) throws {
        let contextCapabilities = Dictionary(
            contextPackages.flatMap(\.capabilities).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        try commit { candidate in
            guard var plugin = candidate.plugin else {
                throw AbilityStudioAuthoringError.pluginRequired
            }
            guard let index = plugin.operations.firstIndex(where: {
                $0.operation == operation
            }) else {
                throw AbilityStudioAuthoringError.operationNotFound(operation)
            }
            let previous = plugin.operations[index].operation
            transform(&plugin.operations[index])
            let next = plugin.operations[index].operation
            if next != previous,
               plugin.operations.enumerated().contains(where: {
                   $0.offset != index && $0.element.operation == next
               }) {
                throw AbilityStudioAuthoringError.operationAlreadyExists(next)
            }
            for realizationIndex in plugin.realizations.indices
            where plugin.realizations[realizationIndex].operation == previous {
                plugin.realizations[realizationIndex].operation = next
            }
            candidate.plugin = plugin
            Self.ensureLocalMutationCapability(
                forOperation: next,
                contextCapabilities: contextCapabilities,
                in: &candidate)
            Self.synchronizeLocalModelContract(
                forOperation: next,
                in: &candidate)
        }
    }

    mutating func removeOperation(_ operation: String) throws {
        guard let plugin = package.plugin else {
            throw AbilityStudioAuthoringError.pluginRequired
        }
        guard plugin.operations.contains(where: { $0.operation == operation }) else {
            throw AbilityStudioAuthoringError.operationNotFound(operation)
        }
        guard plugin.operations.count > 1 else {
            throw AbilityStudioAuthoringError.cannotRemoveLastPluginOperation
        }
        try commit { candidate in
            guard var draftPlugin = candidate.plugin else {
                throw AbilityStudioAuthoringError.pluginRequired
            }
            draftPlugin.operations.removeAll { $0.operation == operation }
            draftPlugin.realizations.removeAll { $0.operation == operation }
            candidate.plugin = draftPlugin
        }
    }

    mutating func addStep(
        _ step: PluginRecipeStepSchema,
        to operation: String,
        lane: AbilityStudioRecipeLane = .action
    ) throws {
        try updateOperation(operation) { target in
            switch lane {
            case .action:
                target.steps.append(step)
            case .cleanup:
                target.cleanupSteps.append(step)
            }
        }
    }

    mutating func updateStep(
        _ stepID: String,
        in operation: String,
        lane: AbilityStudioRecipeLane = .action,
        _ transform: (inout PluginRecipeStepSchema) -> Void
    ) throws {
        guard let target = package.plugin?.operations.first(where: {
            $0.operation == operation
        }) else {
            throw AbilityStudioAuthoringError.operationNotFound(operation)
        }
        guard lane.steps(in: target).contains(where: { $0.id == stepID }) else {
            throw AbilityStudioAuthoringError.stepNotFound(stepID)
        }
        try updateOperation(operation) { target in
            switch lane {
            case .action:
                guard let index = target.steps.firstIndex(where: {
                    $0.id == stepID
                }) else { return }
                transform(&target.steps[index])
            case .cleanup:
                guard let index = target.cleanupSteps.firstIndex(where: {
                    $0.id == stepID
                }) else { return }
                transform(&target.cleanupSteps[index])
            }
        }
    }

    mutating func moveStep(
        _ stepID: String,
        in operation: String,
        to destination: Int,
        lane: AbilityStudioRecipeLane = .action
    ) throws {
        guard let target = package.plugin?.operations.first(where: {
            $0.operation == operation
        }) else {
            throw AbilityStudioAuthoringError.operationNotFound(operation)
        }
        guard lane.steps(in: target).contains(where: { $0.id == stepID }) else {
            throw AbilityStudioAuthoringError.stepNotFound(stepID)
        }
        try updateOperation(operation) { target in
            switch lane {
            case .action:
                Self.moveStep(
                    stepID,
                    to: destination,
                    in: &target.steps)
            case .cleanup:
                Self.moveStep(
                    stepID,
                    to: destination,
                    in: &target.cleanupSteps)
            }
        }
    }

    mutating func removeStep(
        _ stepID: String,
        from operation: String,
        lane: AbilityStudioRecipeLane = .action
    ) throws {
        guard let target = package.plugin?.operations.first(where: {
            $0.operation == operation
        }) else {
            throw AbilityStudioAuthoringError.operationNotFound(operation)
        }
        let steps = lane.steps(in: target)
        guard steps.contains(where: { $0.id == stepID }) else {
            throw AbilityStudioAuthoringError.stepNotFound(stepID)
        }
        guard lane == .cleanup || steps.count > 1 else {
            throw AbilityStudioAuthoringError.cannotRemoveLastRecipeStep(operation)
        }
        try updateOperation(operation) { target in
            switch lane {
            case .action:
                target.steps.removeAll { $0.id == stepID }
            case .cleanup:
                target.cleanupSteps.removeAll { $0.id == stepID }
            }
        }
    }

    /// Renames a captured coordinate space and rewrites every later consumer
    /// in the same foreground recipe atomically. Clearing the capture returns
    /// those consumers to the default content space.
    mutating func renameCapturedCoordinateSpace(
        on stepID: String,
        in operation: String,
        to requestedName: String?
    ) throws {
        guard let target = package.plugin?.operations.first(where: {
            $0.operation == operation
        }),
        let stepIndex = target.steps.firstIndex(where: { $0.id == stepID }) else {
            throw AbilityStudioAuthoringError.stepNotFound(stepID)
        }
        let next = requestedName?.nonEmpty
        let previous = target.steps[stepIndex].captureAnchor
        try updateOperation(operation) { target in
            target.steps[stepIndex].captureAnchor = next
            guard let previous else { return }
            for index in target.steps.indices where index > stepIndex
                && target.steps[index].coordinateSpace == previous {
                target.steps[index].coordinateSpace = next
            }
        }
    }

}

extension PluginOperationInputKind {
    var studioModelSummary: String {
        switch self {
        case .text:
            return "Bounded printable text for a native remote-hands recipe."
        case .number, .integer:
            return "A bounded numeric value for a native remote-hands recipe."
        case .boolean:
            return "A bounded boolean choice for a native remote-hands recipe."
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

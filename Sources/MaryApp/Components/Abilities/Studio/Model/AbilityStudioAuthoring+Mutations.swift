//
//  AbilityStudioAuthoring+Mutations.swift
//

import MaryBrain
import Foundation

extension AbilityStudioAuthoringDocument {

    static func moveStep(
        _ stepID: String,
        to destination: Int,
        in steps: inout [PluginRecipeStepSchema]
    ) {
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else {
            return
        }
        let step = steps.remove(at: index)
        let bounded = max(0, min(destination, steps.count))
        steps.insert(step, at: bounded)
    }

    mutating func addSkill(_ skill: SkillSchema) throws {
        if package.skills.contains(where: { $0.id == skill.id }) {
            throw AbilityStudioAuthoringError.skillAlreadyExists(skill.id)
        }
        try commit { candidate in
            candidate.skills.append(skill)
            candidate.ability.skills.append(skill.id)
        }
    }

    mutating func updateSkill(
        _ skillID: SkillID,
        _ transform: (inout SkillSchema) -> Void
    ) throws {
        try commit { candidate in
            guard let index = candidate.skills.firstIndex(where: { $0.id == skillID }) else {
                throw AbilityStudioAuthoringError.skillNotFound(skillID)
            }
            let previous = candidate.skills[index].id
            transform(&candidate.skills[index])
            let next = candidate.skills[index].id
            if next != previous,
               candidate.skills.enumerated().contains(where: {
                   $0.offset != index && $0.element.id == next
               }) {
                throw AbilityStudioAuthoringError.skillAlreadyExists(next)
            }
            Self.renameSkillReferences(from: previous, to: next, in: &candidate)
        }
    }

    mutating func removeSkill(_ skillID: SkillID) throws {
        guard package.skills.contains(where: { $0.id == skillID }) else {
            throw AbilityStudioAuthoringError.skillNotFound(skillID)
        }
        if let plugin = package.plugin {
            let ownedOperations = Set(plugin.realizations.compactMap {
                $0.skillID == skillID ? $0.operation : nil
            })
            if !ownedOperations.isEmpty,
               plugin.operations.count - ownedOperations.count < 1 {
                throw AbilityStudioAuthoringError.cannotRemoveLastPluginOperation
            }
        }
        try commit { candidate in
            if var plugin = candidate.plugin {
                let ownedOperations = Set(plugin.realizations.compactMap {
                    $0.skillID == skillID ? $0.operation : nil
                })
                plugin.operations.removeAll {
                    ownedOperations.contains($0.operation)
                }
                plugin.realizations.removeAll { $0.skillID == skillID }
                candidate.plugin = plugin
            }
            Self.removeLocalSkill(skillID, from: &candidate)
        }
    }

    mutating func setRealization(
        operation: String,
        skillID: SkillID,
        ownerPackage: MaryAbilityPackage? = nil,
        preference: Int = 100,
        targetClasses: [String] = []
    ) throws {
        try commit { candidate in
            guard var plugin = candidate.plugin else {
                throw AbilityStudioAuthoringError.pluginRequired
            }
            guard plugin.operations.contains(where: { $0.operation == operation }) else {
                throw AbilityStudioAuthoringError.operationNotFound(operation)
            }
            plugin.realizations.removeAll { $0.operation == operation }
            plugin.realizations.append(.init(
                skillID: skillID,
                operation: operation,
                preference: preference,
                targetClasses: targetClasses))
            for targetClass in targetClasses
            where !plugin.application.targetClasses.contains(targetClass) {
                plugin.application.targetClasses.append(targetClass)
            }
            candidate.plugin = plugin
            Self.ensureDependency(on: ownerPackage, in: &candidate)
            Self.synchronizeLocalModelContract(
                forOperation: operation,
                updateInvocation: false,
                in: &candidate)
        }
    }

    /// A Plugin operation without a realization is not a valid executable
    /// declaration, so removing the mapping removes its operation atomically.
    mutating func removeRealization(forOperation operation: String) throws {
        try removeOperation(operation)
    }

    mutating func commit(
        _ transform: (inout MaryAbilityPackage) throws -> Void
    ) throws {
        var candidate = package
        candidate.integrity = nil
        try transform(&candidate)
        let validation = AbilityPackageValidator.validateGraph(
            contextPackages + [candidate])
        try AbilityStudioPackageFactory.requireNoErrors(validation)
        package = candidate
    }

    func nextActionIdentity(
        title: String
    ) -> (skillStem: String, operation: String) {
        let baseSkill = AbilityStudioPackageFactory.portableStem(
            title,
            fallback: "action")
        let operationPrefix = AbilityStudioPackageFactory.callableStem(
            package.package.id.rawValue,
            fallback: "ability")
        let actionCallable = AbilityStudioPackageFactory.callableStem(
            title,
            fallback: "action")
        let existingSkills = Set(package.skills.map(\.id.rawValue))
        let existingOperations = Set(
            package.plugin?.operations.map(\.operation) ?? [])
        var suffix = 1
        while true {
            let skillStem = suffix == 1 ? baseSkill : "\(baseSkill)-\(suffix)"
            let operation = suffix == 1
                ? "\(operationPrefix)_\(actionCallable)"
                : "\(operationPrefix)_\(actionCallable)_\(suffix)"
            let skillID = "\(package.package.id.rawValue).\(skillStem)"
            if !existingSkills.contains(skillID),
               !existingOperations.contains(operation) {
                return (skillStem, operation)
            }
            suffix += 1
        }
    }

    static func modelParameter(
        _ input: PluginOperationInputSchema
    ) -> ModelParameterSchema {
        .init(
            name: input.name,
            type: input.kind.modelType,
            summary: input.kind.studioModelSummary,
            required: input.required && input.defaultValue == nil)
    }

    /// Remote-hand inputs promote a local read Capability to mutation; never auto-demote.
    static func ensureLocalMutationCapability(
        forOperation operation: String,
        contextCapabilities: [CapabilityID: CapabilitySchema],
        in package: inout MaryAbilityPackage
    ) {
        guard let plugin = package.plugin,
              let operationSchema = plugin.operations.first(where: {
                  $0.operation == operation
              }),
              (operationSchema.steps + operationSchema.cleanupSteps).contains(where: { step in
                  switch step.kind {
                  case .keyChord, .typeText, .pointerMove, .pointerClick,
                       .pointerDrag, .pointerSquareDrag, .scroll:
                      return true
                  case .rebindFocusedWindow, .captureAccessibilityAnchor,
                       .wait:
                      return false
                  }
              })
        else { return }

        let realizedSkillIDs = Set(plugin.realizations.compactMap {
            $0.operation == operation ? $0.skillID : nil
        })
        for skill in package.skills where realizedSkillIDs.contains(skill.id) {
            let requiredIDs = Set(skill.requirements.capabilities)
            let localCapabilities = Dictionary(
                package.capabilities.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            let hasMutationContract = requiredIDs.contains { id in
                let capability = localCapabilities[id] ?? contextCapabilities[id]
                guard let capability else { return false }
                switch capability.effect {
                case .reversibleMutation, .mutation, .destructive, .externalCommunication:
                    return true
                case .none, .read:
                    return false
                }
            }
            guard !hasMutationContract,
                  let capabilityIndex = package.capabilities.firstIndex(where: {
                      requiredIDs.contains($0.id) && $0.effect == .read
                  })
            else { continue }
            package.capabilities[capabilityIndex].effect =
                skill.access == .reversible ? .reversibleMutation : .mutation
        }
    }

    static func synchronizeLocalModelContract(
        forOperation operation: String,
        updateInvocation: Bool = true,
        in package: inout MaryAbilityPackage
    ) {
        guard let plugin = package.plugin,
              let operationSchema = plugin.operations.first(where: {
                  $0.operation == operation
              }),
              let skillID = plugin.realizations.first(where: {
                  $0.operation == operation
              })?.skillID,
              let skillIndex = package.skills.firstIndex(where: {
                  $0.id == skillID
              })
        else { return }
        package.skills[skillIndex].modelExposure.parameters = operationSchema.inputs.map {
            modelParameter($0)
        }
        if updateInvocation {
            package.skills[skillIndex].modelExposure.invocationName = operation
        }
    }

    /// `required` is the difference between "this package realizes that one's
    /// meaning" and "this package happens to call it". Only the first may
    /// promote an existing optional dependency: a required dependency is what
    /// `extendedDisciplines` reads, so promoting one silently changes what an
    /// expertise claims to extend.
    static func ensureDependency(
        on ownerPackage: MaryAbilityPackage?,
        required: Bool = true,
        in candidate: inout MaryAbilityPackage
    ) {
        guard let ownerPackage,
              ownerPackage.package.id != candidate.package.id else { return }
        if let index = candidate.dependencies.firstIndex(where: {
            $0.packageID == ownerPackage.package.id
        }) {
            if required { candidate.dependencies[index].optional = false }
            if candidate.dependencies[index].minimumVersion
                < ownerPackage.package.version {
                candidate.dependencies[index].minimumVersion =
                    ownerPackage.package.version
            }
        } else {
            candidate.dependencies.append(.init(
                packageID: ownerPackage.package.id,
                minimumVersion: ownerPackage.package.version,
                optional: !required))
        }
    }

    static func renameSkillReferences(
        from previous: SkillID,
        to next: SkillID,
        in candidate: inout MaryAbilityPackage
    ) {
        candidate.ability.skills = candidate.ability.skills.map {
            $0 == previous ? next : $0
        }
        for skillIndex in candidate.skills.indices {
            candidate.skills[skillIndex].routing.fallbacks =
                candidate.skills[skillIndex].routing.fallbacks.map {
                    $0 == previous ? next : $0
                }
        }
        for projectionIndex in candidate.totemProjections.indices {
            candidate.totemProjections[projectionIndex].skills =
                candidate.totemProjections[projectionIndex].skills.map {
                    $0 == previous ? next : $0
                }
        }
        for fixtureIndex in candidate.fixtures.indices
        where candidate.fixtures[fixtureIndex].expectedSkill == previous {
            candidate.fixtures[fixtureIndex].expectedSkill = next
        }
        if var plugin = candidate.plugin {
            for index in plugin.realizations.indices
            where plugin.realizations[index].skillID == previous {
                plugin.realizations[index].skillID = next
            }
            candidate.plugin = plugin
        }
    }

    static func removeLocalSkill(
        _ skillID: SkillID,
        from candidate: inout MaryAbilityPackage
    ) {
        let capabilityIDs = Set(candidate.skills.first(where: {
            $0.id == skillID
        })?.requirements.capabilities ?? [])
        candidate.skills.removeAll { $0.id == skillID }
        candidate.ability.skills.removeAll { $0 == skillID }
        for skillIndex in candidate.skills.indices {
            candidate.skills[skillIndex].routing.fallbacks.removeAll {
                $0 == skillID
            }
        }
        for projectionIndex in candidate.totemProjections.indices {
            candidate.totemProjections[projectionIndex].skills.removeAll {
                $0 == skillID
            }
        }
        for fixtureIndex in candidate.fixtures.indices
        where candidate.fixtures[fixtureIndex].expectedSkill == skillID {
            candidate.fixtures[fixtureIndex].expectedSkill = nil
        }
        let stillRequired = Set(candidate.skills.flatMap {
            $0.requirements.capabilities
        })
        candidate.capabilities.removeAll {
            capabilityIDs.contains($0.id) && !stillRequired.contains($0.id)
        }
    }

}

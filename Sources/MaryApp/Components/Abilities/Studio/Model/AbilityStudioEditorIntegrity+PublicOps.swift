//
//  AbilityStudioEditorIntegrity+PublicOps.swift
//

import MaryBrain
import Foundation

extension AbilityStudioEditorIntegrity {

    static func renameApplicationAffinity(
        in package: inout MaryAbilityPackage,
        from previous: String,
        to next: String
    ) throws {
        guard var applications = package.ability.applications,
              let index = applications.firstIndex(where: { $0.id == previous })
        else {
            throw MutationError.applicationNotFound(previous)
        }
        guard previous == next || !applications.contains(where: { $0.id == next }) else {
            throw MutationError.duplicateApplicationID(next)
        }

        applications[index].id = next
        package.ability.applications = applications
        rewriteNamedApplication(in: &package.ability.routing, from: previous, to: next)
        for skillIndex in package.skills.indices {
            rewriteNamedApplication(
                in: &package.skills[skillIndex].routing,
                from: previous,
                to: next)
        }
    }

    /// Changes the provider-wide target vocabulary and moves every local
    /// reference that was scoped to the prior vocabulary in the same atomic
    /// edit. External portable Skills are intentionally not rewritten.
    static func replacePluginTargetClasses(
        in package: inout MaryAbilityPackage,
        with targetClasses: [String]
    ) throws {
        guard !targetClasses.isEmpty else {
            throw MutationError.targetClassesRequired
        }
        guard var plugin = package.plugin else {
            throw MutationError.pluginRequired
        }

        let previous = Set(plugin.application.targetClasses)
        let next = orderedUnique(targetClasses)
        let adapterIDs = Set(plugin.adapters.map(\.id))
        let localSkillIDs = Set(plugin.realizations.map(\.skillID))
            .intersection(Set(package.skills.map(\.id)))

        plugin.application.targetClasses = next
        for realizationIndex in plugin.realizations.indices {
            plugin.realizations[realizationIndex].targetClasses = rewriteTargets(
                plugin.realizations[realizationIndex].targetClasses,
                replacing: previous,
                with: next)
        }
        package.plugin = plugin

        var scopedCapabilities = Set<CapabilityID>()
        for skillIndex in package.skills.indices {
            if localSkillIDs.contains(package.skills[skillIndex].id) {
                scopedCapabilities.formUnion(
                    package.skills[skillIndex].requirements.capabilities)
                rewriteTargetClass(
                    in: &package.skills[skillIndex].routing,
                    replacing: previous,
                    with: next)
            }
            for bindingIndex in package.skills[skillIndex].execution.bindings.indices
            where adapterIDs.contains(
                package.skills[skillIndex].execution.bindings[bindingIndex].adapterID) {
                package.skills[skillIndex].execution.bindings[bindingIndex].targetClasses =
                    rewriteTargets(
                        package.skills[skillIndex].execution.bindings[bindingIndex].targetClasses,
                        replacing: previous,
                        with: next)
            }
        }

        for capabilityIndex in package.capabilities.indices
        where scopedCapabilities.contains(package.capabilities[capabilityIndex].id) {
            package.capabilities[capabilityIndex].constraints = rewriteTargetConstraints(
                package.capabilities[capabilityIndex].constraints,
                replacing: previous,
                with: next)
        }
    }

    static func visuallyAuthorableKinds(for skill: SkillSchema) -> [SkillKind] {
        skill.kind == .workflow ? [.workflow] : [.cognitive, .effectful]
    }

    static func canTransitionSkillKind(
        in package: MaryAbilityPackage,
        skillID: SkillID,
        to kind: SkillKind
    ) -> Bool {
        guard let skill = package.skills.first(where: { $0.id == skillID }) else {
            return false
        }
        if kind == skill.kind { return true }
        guard skill.kind != .workflow, kind != .workflow else { return false }
        if kind == .cognitive {
            return skill.execution.bindings.isEmpty
                && skill.execution.steps.isEmpty
                && package.plugin?.realizations.contains(where: {
                    $0.skillID == skillID
                }) != true
        }
        return skill.execution.steps.isEmpty
    }

    static func transitionSkillKind(
        in package: inout MaryAbilityPackage,
        skillID: SkillID,
        to kind: SkillKind
    ) throws {
        guard let index = package.skills.firstIndex(where: { $0.id == skillID }) else {
            throw MutationError.skillNotFound(skillID)
        }
        let current = package.skills[index]
        if current.kind == kind { return }
        guard current.kind != .workflow, kind != .workflow else {
            throw MutationError.workflowKindIsSourceOnly
        }
        guard current.execution.steps.isEmpty else {
            throw MutationError.skillHasWorkflowSteps(skillID)
        }

        switch kind {
        case .cognitive:
            guard current.execution.bindings.isEmpty else {
                throw MutationError.skillHasBindings(skillID)
            }
            guard package.plugin?.realizations.contains(where: {
                $0.skillID == skillID
            }) != true else {
                throw MutationError.skillHasPluginRealization(skillID)
            }
            package.skills[index].kind = .cognitive
            package.skills[index].access = .seamless
            package.skills[index].execution = .init(kind: .cognitive)
            package.skills[index].modelExposure.inheritsBindingContract = false
            // A cognitive Skill has no hands, so an execution-shaped artifact
            // role cannot survive the transition. Observation and utility are
            // honest for any kind and are preserved.
            switch package.skills[index].semantics?.artifactRole {
            case .create, .mutate, .plan:
                package.skills[index].semantics = nil
            case .observe, .utility, nil:
                break
            }
        case .effectful:
            package.skills[index].kind = .effectful
            package.skills[index].execution = .init(
                kind: .binding,
                realizationPolicy: .pluginRealizations)
        case .workflow:
            throw MutationError.workflowKindIsSourceOnly
        }
    }

    /// Adopt a compiled faculty's validated contract; never a weaker one.
    static func adoptInstalledFaculty(
        _ option: AbilityStudioInstalledFacultyOption,
        for skillID: SkillID,
        in package: inout MaryAbilityPackage
    ) throws {
        let manifest = option.manifest
        let operation = option.operation
        let runtime = option.runtimeSkill
        let sourcePackage = option.sourcePackage
        guard manifest.resolvedProvider.pluginClass == .runtime,
              manifest.isAvailable,
              operation.isAvailable,
              operation.adapterID == manifest.adapterID,
              manifest.operations.contains(where: {
                  $0.adapterID == manifest.adapterID
                      && $0.operation == operation.operation
                      && $0.isAvailable
              }),
              !RuntimePrimitiveOperations.contains(operation.operation)
        else {
            throw MutationError.installedFacultyUnavailable(
                manifest.adapterID,
                operation.operation)
        }
        guard runtime.packageID == sourcePackage.package.id,
              runtime.availability.readiness == .ready,
              runtime.availability.selectedBinding.map({
                  $0.adapterID == manifest.adapterID
                      && $0.operation == operation.operation
              }) == true,
              let sourceSkill = sourcePackage.skills.first(where: {
                  $0.id == runtime.skill.id
              }),
              let exactBinding = sourceSkill.execution.bindings.first(where: {
                  $0.adapterID == manifest.adapterID
                      && $0.operation == operation.operation
              }),
              let localIndex = package.skills.firstIndex(where: {
                  $0.id == skillID
              })
        else {
            throw MutationError.installedFacultySourceMismatch(runtime.skill.id)
        }

        let local = package.skills[localIndex]
        var adopted = runtime.skill
        adopted.id = local.id
        adopted.title = local.title
        adopted.summary = local.summary
        adopted.routing = local.routing
        adopted.execution = .init(
            kind: .binding,
            bindings: [.init(
                adapterID: manifest.adapterID,
                operation: operation.operation,
                preference: exactBinding.preference,
                targetClasses: exactBinding.targetClasses)],
            realizationPolicy: .authoredBindings)
        adopted.modelExposure.invocationName =
            local.modelExposure.invocationName
                ?? runtime.skill.modelExposure.invocationName
        package.skills[localIndex] = adopted

        if var plugin = package.plugin {
            plugin.realizations.removeAll { $0.skillID == skillID }
            package.plugin = plugin
        }

        package.dependencies = mergeDependencies(
            package.dependencies,
            sourcePackage.dependencies + [.init(
                packageID: sourcePackage.package.id,
                minimumVersion: sourcePackage.package.version)])
        mergeSourceApplications(
            runtime.ability.applications ?? [],
            into: &package.ability.applications)
    }

    /// True when a Skill crosses Mary's compiled installed-faculty boundary.
    /// Visual controls use this single policy decision to pin every field that
    /// participates in provider compatibility.
    static func hasExternalInstalledFacultyContract(
        _ skill: SkillSchema,
        in package: MaryAbilityPackage,
        snapshot: AbilityRuntimeSnapshot
    ) -> Bool {
        let localAdapters = Set(package.plugin?.adapters.map(\.id) ?? [])
        return skill.execution.bindings.contains {
            !localAdapters.contains($0.adapterID)
        }
    }

    /// Application identities imported with installed faculty are provenance,
    /// not author-tunable aliases. Pin every matching source identity even if
    /// several source packages publish the same compiled operation.
    static func pinnedInstalledApplicationIDs(
        in package: MaryAbilityPackage,
        snapshot: AbilityRuntimeSnapshot
    ) -> Set<String> {
        let sourceIDs = Set(installedFacultySourcePackages(
            in: package,
            snapshot: snapshot)
            .flatMap { $0.ability.applications ?? [] }
            .map(\.id))
        guard package.skills.contains(where: {
            hasExternalInstalledFacultyContract(
                $0,
                in: package,
                snapshot: snapshot)
        }) else { return sourceIDs }
        // If the provider/source is disconnected, provenance cannot be
        // reconstructed safely. Keep all persisted affinities pinned rather
        // than turning an outage into authority to rewrite identity.
        return sourceIDs.isEmpty
            ? Set((package.ability.applications ?? []).map(\.id))
            : sourceIDs
    }

    /// Required source and transitive dependency rows are likewise part of
    /// the adopted faculty's provenance and cannot be weakened visually.
    static func pinnedInstalledDependencyIDs(
        in package: MaryAbilityPackage,
        snapshot: AbilityRuntimeSnapshot
    ) -> Set<PackageID> {
        let sources = installedFacultySourcePackages(in: package, snapshot: snapshot)
        let sourceIDs = Set(sources.flatMap { source in
            [source.package.id] + source.dependencies.map(\.packageID)
        })
        guard package.skills.contains(where: {
            hasExternalInstalledFacultyContract(
                $0,
                in: package,
                snapshot: snapshot)
        }) else { return sourceIDs }
        return sourceIDs.isEmpty
            ? Set(package.dependencies.map(\.packageID))
            : sourceIDs
    }

    static func renamePluginOperation(
        in package: inout MaryAbilityPackage,
        from previous: String,
        to next: String
    ) throws {
        guard var plugin = package.plugin,
              let operationIndex = plugin.operations.firstIndex(where: {
                  $0.operation == previous
              })
        else {
            throw MutationError.operationNotFound(previous)
        }
        guard previous == next || !plugin.operations.contains(where: {
            $0.operation == next
        }) else {
            throw MutationError.operationAlreadyExists(next)
        }

        let adapterIDs = Set(plugin.adapters.map(\.id))
        plugin.operations[operationIndex].operation = next
        for realizationIndex in plugin.realizations.indices
        where plugin.realizations[realizationIndex].operation == previous {
            plugin.realizations[realizationIndex].operation = next
        }
        package.plugin = plugin

        for skillIndex in package.skills.indices {
            for bindingIndex in package.skills[skillIndex].execution.bindings.indices
            where package.skills[skillIndex].execution.bindings[bindingIndex].operation == previous
                && adapterIDs.contains(
                    package.skills[skillIndex].execution.bindings[bindingIndex].adapterID) {
                package.skills[skillIndex].execution.bindings[bindingIndex].operation = next
            }
            for stepIndex in package.skills[skillIndex].execution.steps.indices
            where package.skills[skillIndex].execution.steps[stepIndex].operation == previous {
                package.skills[skillIndex].execution.steps[stepIndex].operation = next
            }
        }
        synchronizeLocalModelContract(forOperation: next, in: &package)
    }

    static func updatePluginOperation(
        in package: inout MaryAbilityPackage,
        operation: String,
        _ change: (inout PluginOperationSchema) -> Void
    ) throws {
        guard var plugin = package.plugin,
              let operationIndex = plugin.operations.firstIndex(where: {
                  $0.operation == operation
              })
        else {
            throw MutationError.operationNotFound(operation)
        }
        change(&plugin.operations[operationIndex])
        package.plugin = plugin
        synchronizeLocalModelContract(
            forOperation: plugin.operations[operationIndex].operation,
            in: &package)
    }

    static func addPluginInput(
        _ input: PluginOperationInputSchema,
        to operation: String,
        in package: inout MaryAbilityPackage
    ) throws {
        guard var plugin = package.plugin,
              let operationIndex = plugin.operations.firstIndex(where: {
                  $0.operation == operation
              })
        else {
            throw MutationError.operationNotFound(operation)
        }
        guard !plugin.operations[operationIndex].inputs.contains(where: {
            $0.name == input.name
        }) else {
            throw MutationError.inputAlreadyExists(input.name)
        }
        plugin.operations[operationIndex].inputs.append(input)
        let connected: Bool
        if [.number, .integer].contains(input.kind) {
            connected = connectFirstFixedNumericExpression(
                to: input.name,
                in: &plugin.operations[operationIndex])
        } else if input.kind == .text {
            connected = connectFirstFixedText(
                to: input.name,
                in: &plugin.operations[operationIndex])
        } else {
            connected = false
        }
        guard connected else {
            throw MutationError.noCompatibleRecipeExpression(
                operation,
                input.kind)
        }
        package.plugin = plugin
        synchronizeLocalModelContract(forOperation: operation, in: &package)
    }

    static func renamePluginInput(
        in package: inout MaryAbilityPackage,
        operation: String,
        from previous: String,
        to next: String
    ) throws {
        guard var plugin = package.plugin,
              let operationIndex = plugin.operations.firstIndex(where: {
                  $0.operation == operation
              }),
              let inputIndex = plugin.operations[operationIndex].inputs.firstIndex(where: {
                  $0.name == previous
              })
        else {
            throw MutationError.inputNotFound(previous)
        }
        guard previous == next || !plugin.operations[operationIndex].inputs.contains(where: {
            $0.name == next
        }) else {
            throw MutationError.inputAlreadyExists(next)
        }

        plugin.operations[operationIndex].inputs[inputIndex].name = next
        for stepIndex in plugin.operations[operationIndex].steps.indices {
            rewriteInput(
                in: &plugin.operations[operationIndex].steps[stepIndex],
                from: previous,
                to: next)
        }
        for stepIndex in plugin.operations[operationIndex].cleanupSteps.indices {
            rewriteInput(
                in: &plugin.operations[operationIndex].cleanupSteps[stepIndex],
                from: previous,
                to: next)
        }
        package.plugin = plugin
        for skillIndex in localSkillIndices(
            realizing: operation,
            plugin: plugin,
            package: package) {
            for parameterIndex in package.skills[skillIndex].modelExposure.parameters.indices
            where package.skills[skillIndex].modelExposure.parameters[parameterIndex].name
                == previous {
                package.skills[skillIndex].modelExposure.parameters[parameterIndex].name = next
            }
        }
        synchronizeLocalModelContract(forOperation: operation, in: &package)
    }

    static func removePluginInput(
        _ inputName: String,
        from operation: String,
        in package: inout MaryAbilityPackage
    ) throws {
        guard var plugin = package.plugin,
              let operationIndex = plugin.operations.firstIndex(where: {
                  $0.operation == operation
              }),
              let inputIndex = plugin.operations[operationIndex].inputs.firstIndex(where: {
                  $0.name == inputName
              })
        else {
            throw MutationError.inputNotFound(inputName)
        }
        let input = plugin.operations[operationIndex].inputs[inputIndex]
        var steps = plugin.operations[operationIndex].steps
        for stepIndex in steps.indices {
            try detachInput(
                inputName,
                input: input,
                from: &steps[stepIndex])
        }
        plugin.operations[operationIndex].steps = steps
        var cleanupSteps = plugin.operations[operationIndex].cleanupSteps
        for stepIndex in cleanupSteps.indices {
            try detachInput(
                inputName,
                input: input,
                from: &cleanupSteps[stepIndex])
        }
        plugin.operations[operationIndex].cleanupSteps = cleanupSteps
        plugin.operations[operationIndex].inputs.remove(at: inputIndex)
        package.plugin = plugin
        synchronizeLocalModelContract(forOperation: operation, in: &package)
    }

}

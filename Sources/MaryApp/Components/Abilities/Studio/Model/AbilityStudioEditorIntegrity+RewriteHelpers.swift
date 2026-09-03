//
//  AbilityStudioEditorIntegrity+RewriteHelpers.swift
//

import MaryBrain
import Foundation

extension AbilityStudioEditorIntegrity {

    static func rewriteNamedApplication(
        in policy: inout RoutingPolicySchema,
        from previous: String,
        to next: String
    ) {
        if var eligibility = policy.eligibility {
            rewriteNamedApplication(in: &eligibility, from: previous, to: next)
            policy.eligibility = eligibility
        }
        for index in policy.excludes.indices {
            rewriteNamedApplication(
                in: &policy.excludes[index],
                from: previous,
                to: next)
        }
    }

    static func rewriteNamedApplication(
        in predicate: inout RoutingPredicate,
        from previous: String,
        to next: String
    ) {
        if predicate.kind == .namedApplication, predicate.value == previous {
            predicate.value = next
        }
        for index in predicate.children.indices {
            rewriteNamedApplication(
                in: &predicate.children[index],
                from: previous,
                to: next)
        }
    }

    static func rewriteTargetClass(
        in policy: inout RoutingPolicySchema,
        replacing previous: Set<String>,
        with next: [String]
    ) {
        if var eligibility = policy.eligibility {
            rewriteTargetClass(in: &eligibility, replacing: previous, with: next)
            policy.eligibility = eligibility
        }
        for index in policy.excludes.indices {
            rewriteTargetClass(
                in: &policy.excludes[index],
                replacing: previous,
                with: next)
        }
    }

    static func rewriteTargetClass(
        in predicate: inout RoutingPredicate,
        replacing previous: Set<String>,
        with next: [String]
    ) {
        if predicate.kind == .targetClass,
           let value = predicate.value,
           previous.contains(value) {
            if next.count == 1 {
                predicate.value = next[0]
            } else {
                predicate = .init(
                    kind: .any,
                    children: next.map {
                        .init(kind: .targetClass, value: $0)
                    })
            }
            return
        }
        for index in predicate.children.indices {
            rewriteTargetClass(
                in: &predicate.children[index],
                replacing: previous,
                with: next)
        }
    }

    static func rewriteTargets(
        _ targets: [String],
        replacing previous: Set<String>,
        with next: [String]
    ) -> [String] {
        guard targets.contains(where: previous.contains) else { return targets }
        return orderedUnique(targets.filter { !previous.contains($0) } + next)
    }

    static func rewriteTargetConstraints(
        _ constraints: [CapabilityConstraint],
        replacing previous: Set<String>,
        with next: [String]
    ) -> [CapabilityConstraint] {
        guard constraints.contains(where: {
            $0.kind == .allowedTargetClass && previous.contains($0.value)
        }) else { return constraints }

        let retained = constraints.filter {
            $0.kind != .allowedTargetClass || !previous.contains($0.value)
        }
        return orderedUniqueConstraints(
            retained + next.map {
                .init(kind: .allowedTargetClass, value: $0)
            })
    }

    static func synchronizeLocalModelContract(
        forOperation operation: String,
        in package: inout MaryAbilityPackage
    ) {
        guard let plugin = package.plugin,
              let operationSchema = plugin.operations.first(where: {
                  $0.operation == operation
              })
        else { return }

        for skillIndex in localSkillIndices(
            realizing: operation,
            plugin: plugin,
            package: package) {
            package.skills[skillIndex].modelExposure.parameters =
                operationSchema.inputs.map { input in
                    .init(
                        name: input.name,
                        type: input.kind.modelType,
                        summary: input.kind.studioModelSummary,
                        required: input.required && input.defaultValue == nil)
                }
            package.skills[skillIndex].modelExposure.invocationName = operation
        }
    }

    static func localSkillIndices(
        realizing operation: String,
        plugin: PluginSchema,
        package: MaryAbilityPackage
    ) -> [Int] {
        let skillIDs = Set(plugin.realizations.compactMap {
            $0.operation == operation ? $0.skillID : nil
        })
        return package.skills.indices.filter {
            skillIDs.contains(package.skills[$0].id)
        }
    }

    static func rewriteInput(
        in step: inout PluginRecipeStepSchema,
        from previous: String,
        to next: String
    ) {
        if var point = step.point {
            rewriteInput(in: &point.x, from: previous, to: next)
            rewriteInput(in: &point.y, from: previous, to: next)
            step.point = point
        }
        if var rect = step.rect {
            rewriteInput(in: &rect.x, from: previous, to: next)
            rewriteInput(in: &rect.y, from: previous, to: next)
            rewriteInput(in: &rect.width, from: previous, to: next)
            rewriteInput(in: &rect.height, from: previous, to: next)
            step.rect = rect
        }
        if var text = step.text {
            if text.input == previous { text.input = next }
            step.text = text
        }
        if var deltaX = step.deltaX {
            rewriteInput(in: &deltaX, from: previous, to: next)
            step.deltaX = deltaX
        }
        if var deltaY = step.deltaY {
            rewriteInput(in: &deltaY, from: previous, to: next)
            step.deltaY = deltaY
        }
    }

    static func rewriteInput(
        in scalar: inout PluginScalarExpression,
        from previous: String,
        to next: String
    ) {
        if scalar.input == previous { scalar.input = next }
    }

    static func detachInput(
        _ inputName: String,
        input: PluginOperationInputSchema,
        from step: inout PluginRecipeStepSchema
    ) throws {
        let numericFallback = input.defaultValue.flatMap(Double.init)
        if var point = step.point {
            try detachInput(inputName, fallback: numericFallback, from: &point.x)
            try detachInput(inputName, fallback: numericFallback, from: &point.y)
            step.point = point
        }
        if var rect = step.rect {
            try detachInput(inputName, fallback: numericFallback, from: &rect.x)
            try detachInput(inputName, fallback: numericFallback, from: &rect.y)
            try detachInput(inputName, fallback: numericFallback, from: &rect.width)
            try detachInput(inputName, fallback: numericFallback, from: &rect.height)
            step.rect = rect
        }
        if var text = step.text, text.input == inputName {
            guard let literal = text.defaultValue ?? input.defaultValue else {
                throw MutationError.inputStillRequiredByRecipe(inputName)
            }
            text = .init(value: literal)
            step.text = text
        }
        if var deltaX = step.deltaX {
            try detachInput(inputName, fallback: numericFallback, from: &deltaX)
            step.deltaX = deltaX
        }
        if var deltaY = step.deltaY {
            try detachInput(inputName, fallback: numericFallback, from: &deltaY)
            step.deltaY = deltaY
        }
    }

    static func detachInput(
        _ inputName: String,
        fallback: Double?,
        from scalar: inout PluginScalarExpression
    ) throws {
        guard scalar.input == inputName else { return }
        guard let literal = scalar.defaultValue ?? fallback else {
            throw MutationError.inputStillRequiredByRecipe(inputName)
        }
        scalar = .init(value: literal)
    }

    static func connectFirstFixedNumericExpression(
        to inputName: String,
        in operation: inout PluginOperationSchema
    ) -> Bool {
        for stepIndex in operation.steps.indices {
            if var point = operation.steps[stepIndex].point {
                if connect(to: inputName, scalar: &point.x)
                    || connect(to: inputName, scalar: &point.y) {
                    operation.steps[stepIndex].point = point
                    return true
                }
            }
            if var rect = operation.steps[stepIndex].rect {
                if connect(to: inputName, scalar: &rect.x)
                    || connect(to: inputName, scalar: &rect.y)
                    || connect(to: inputName, scalar: &rect.width)
                    || connect(to: inputName, scalar: &rect.height) {
                    operation.steps[stepIndex].rect = rect
                    return true
                }
            }
            if var deltaX = operation.steps[stepIndex].deltaX,
               connect(to: inputName, scalar: &deltaX) {
                operation.steps[stepIndex].deltaX = deltaX
                return true
            }
            if var deltaY = operation.steps[stepIndex].deltaY,
               connect(to: inputName, scalar: &deltaY) {
                operation.steps[stepIndex].deltaY = deltaY
                return true
            }
        }
        return false
    }

    static func connectFirstFixedText(
        to inputName: String,
        in operation: inout PluginOperationSchema
    ) -> Bool {
        for stepIndex in operation.steps.indices {
            guard let expression = operation.steps[stepIndex].text,
                  expression.input == nil,
                  let literal = expression.value else { continue }
            operation.steps[stepIndex].text = .init(
                input: inputName,
                defaultValue: literal)
            return true
        }
        return false
    }

    static func connect(
        to inputName: String,
        scalar: inout PluginScalarExpression
    ) -> Bool {
        guard scalar.input == nil, let literal = scalar.value else { return false }
        scalar = .init(input: inputName, defaultValue: literal)
        return true
    }

    static func mergeDependencies(
        _ current: [AbilityPackageDependency],
        _ required: [AbilityPackageDependency]
    ) -> [AbilityPackageDependency] {
        var merged: [PackageID: AbilityPackageDependency] = [:]
        for dependency in current + required {
            guard var prior = merged[dependency.packageID] else {
                merged[dependency.packageID] = dependency
                continue
            }
            if prior.minimumVersion < dependency.minimumVersion {
                prior.minimumVersion = dependency.minimumVersion
            }
            prior.optional = prior.optional && dependency.optional
            merged[dependency.packageID] = prior
        }
        return merged.values.sorted {
            $0.packageID.rawValue < $1.packageID.rawValue
        }
    }

    static func mergeSourceApplications(
        _ source: [ApplicationAffinity],
        into applications: inout [ApplicationAffinity]?
    ) {
        guard !source.isEmpty else { return }
        var merged = applications ?? []
        for application in source {
            if let index = merged.firstIndex(where: { $0.id == application.id }) {
                merged[index] = application
            } else {
                merged.append(application)
            }
        }
        applications = merged
    }

    static func installedFacultySourcePackages(
        in package: MaryAbilityPackage,
        snapshot: AbilityRuntime.Snapshot
    ) -> [MaryAbilityPackage] {
        let localAdapters = Set(package.plugin?.adapters.map(\.id) ?? [])
        let boundOperations = Set(package.skills.flatMap { skill in
            skill.execution.bindings.compactMap { binding -> String? in
                guard !localAdapters.contains(binding.adapterID) else { return nil }
                return "\(binding.adapterID.rawValue)|\(binding.operation)"
            }
        })
        guard !boundOperations.isEmpty else { return [] }
        return snapshot.records.compactMap { record in
            record.package.skills.contains(where: { skill in
                skill.execution.bindings.contains(where: { binding in
                    boundOperations.contains(
                        "\(binding.adapterID.rawValue)|\(binding.operation)")
                })
            }) ? record.package : nil
        }
    }

    static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func orderedUniqueConstraints(
        _ constraints: [CapabilityConstraint]
    ) -> [CapabilityConstraint] {
        var seen = Set<String>()
        return constraints.filter {
            seen.insert("\($0.kind.rawValue)|\($0.value)").inserted
        }
    }

}

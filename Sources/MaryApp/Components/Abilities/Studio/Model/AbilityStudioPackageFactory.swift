//
//  AbilityStudioPackageFactory.swift
//  Mary
//
//  WHAT: Build `.mary` packages from native-app or installed-faculty templates.
//  IN:   AbilityStudioAuthoring.swift (sibling split)
//  OUT:  AbilityStudioViewModel authoring
//

import MaryBrain
import Foundation

enum AbilityStudioPackageFactory {
    static func nativeApplication(
        _ template: AbilityStudioNativeApplicationTemplate
    ) throws -> MaryAbilityPackage {
        try validatePackageID(template.packageID)
        guard bundleIdentifierIsValid(template.bundleIdentifier) else {
            throw AbilityStudioAuthoringError.invalidBundleIdentifier(
                template.bundleIdentifier)
        }

        let id = template.packageID.rawValue
        let callablePrefix = callableStem(id, fallback: "ability")
        let targetClass = "\(id)-application"
        let skillID = SkillID("\(id).verify-surface")
        let capabilityID = CapabilityID("\(id).surface-verify")
        let adapterID = AdapterID("\(id).managed-ui")
        let operation = "\(callablePrefix)_verify_surface"
        let capability = CapabilitySchema(
            id: capabilityID,
            title: "Verify \(template.title) Surface",
            summary: "Verify the focused native interaction surface.",
            effect: .read,
            constraints: nativeStageConstraints(targetClasses: [targetClass]))
        let skill = SkillSchema(
            id: skillID,
            title: "Verify \(template.title) Surface",
            summary: "Verify that the already-running application has a focused native interaction surface.",
            kind: .effectful,
            requirements: .init(capabilities: [capabilityID]),
            routing: .init(eligibility: .init(kind: .targetClass, value: targetClass)),
            execution: .init(kind: .binding, realizationPolicy: .pluginRealizations),
            modelExposure: .init(
                invocationName: operation,
                inheritsBindingContract: true),
            usesStage: true,
            timeoutSeconds: 10)

        let package = MaryAbilityPackage(
            package: .init(
                id: template.packageID,
                version: "1.0.0",
                publisher: template.publisher,
                summary: "Teaches Mary how to operate \(template.title) through native faculties.",
                minimumMaryVersion: "1.0.0"),
            ability: .init(
                id: AbilityID(id),
                title: template.title,
                summary: "Expertise in \(template.title), performed through Mary-owned native interaction.",
                tint: template.tint,
                aliases: [],
                triggers: .init(),
                skills: [skillID],
                operatingPolicy: nativeOperatingPolicy(title: template.title),
                routing: .init(
                    eligibility: .init(kind: .namedApplication, value: id),
                    preference: 100,
                    conflictGroup: "ability",
                    conflictPolicy: .preferFocusedWorkspace,
                    requiredSourceResolution: .application),
                paradigm: .applicationExpertise),
            skills: [skill],
            capabilities: [capability],
            plugin: .init(
                id: id,
                title: template.title,
                application: .init(
                    id: id,
                    title: template.title,
                    bundleIdentifiers: [template.bundleIdentifier],
                    bundleNames: template.bundleName.map { [$0] } ?? [],
                    targetClasses: [targetClass]),
                adapter: .init(
                    id: adapterID,
                    title: "\(template.title) Native Interaction"),
                operations: [.init(
                    operation: operation,
                    title: "Verify \(template.title) Surface",
                    summary: "Wait briefly, then verify the exact process still owns a focused window.",
                    adapterID: adapterID,
                    semantics: .init(role: .utility),
                    steps: [.init(
                        id: "settle",
                        kind: .wait,
                        durationSeconds: 0.1)],
                    postconditions: [
                        .applicationFrontmost,
                        .applicationWindowAvailable,
                    ])],
                realizations: [.init(
                    skillID: skillID,
                    operation: operation,
                    targetClasses: [targetClass])]))
        try requireNoErrors(AbilityPackageValidator.validateGraph([package]))
        return package
    }

    static func installedFaculty(
        _ template: AbilityStudioInstalledFacultyTemplate
    ) throws -> MaryAbilityPackage {
        try validatePackageID(template.packageID)
        let faculty = template.faculty
        let manifest = faculty.manifest
        let sourceRuntime = faculty.runtimeSkill
        let sourcePackage = faculty.sourcePackage
        guard manifest.resolvedProvider.pluginClass == .runtime else {
            throw AbilityStudioAuthoringError.installedFacultyMustBeNative(
                manifest.adapterID)
        }
        guard manifest.isAvailable,
              let operation = manifest.operations.first(where: {
                  $0.adapterID == manifest.adapterID
                      && $0.operation == faculty.operation.operation
                      && $0.isAvailable
              }),
              !RuntimePrimitiveOperations.contains(operation.operation)
        else {
            throw AbilityStudioAuthoringError.installedOperationNotFound(
                adapterID: manifest.adapterID,
                operation: faculty.operation.operation)
        }
        guard sourcePackage.package.id == sourceRuntime.packageID,
              sourceRuntime.availability.readiness == .ready,
              sourceRuntime.availability.selectedBinding.map({
                  $0.adapterID == manifest.adapterID
                      && $0.operation == operation.operation
              }) == true,
              let authoredSourceSkill = sourcePackage.skills.first(where: {
                  $0.id == sourceRuntime.skill.id
              }),
              let exactBinding = authoredSourceSkill.execution.bindings.first(where: {
                  $0.adapterID == manifest.adapterID
                      && $0.operation == operation.operation
              })
        else {
            throw AbilityStudioAuthoringError.installedOperationNotFound(
                adapterID: manifest.adapterID,
                operation: operation.operation)
        }

        let id = template.packageID.rawValue
        let skillStem = portableStem(
            sourceRuntime.skill.id.rawValue.split(separator: ".").last.map(String.init)
                ?? operation.operation,
            fallback: "perform")
        let skillID = SkillID("\(id).\(skillStem)")
        let invocationPrefix = callableStem(id, fallback: "ability")
        let invocationOperation = callableStem(
            operation.operation,
            fallback: "perform")
        let invocation = "\(invocationPrefix)_\(invocationOperation)"
        var skill = sourceRuntime.skill
        skill.id = skillID
        skill.routing.fallbacks = []
        skill.execution = .init(
            kind: .binding,
            bindings: [.init(
                adapterID: manifest.adapterID,
                operation: operation.operation,
                preference: exactBinding.preference,
                targetClasses: exactBinding.targetClasses)],
            realizationPolicy: .authoredBindings)
        skill.modelExposure.invocationName = invocation

        var dependencies = sourcePackage.dependencies
        if let index = dependencies.firstIndex(where: {
            $0.packageID == sourcePackage.package.id
        }) {
            dependencies[index].optional = false
            if dependencies[index].minimumVersion < sourcePackage.package.version {
                dependencies[index].minimumVersion = sourcePackage.package.version
            }
        } else {
            dependencies.append(.init(
                packageID: sourcePackage.package.id,
                minimumVersion: sourcePackage.package.version))
        }
        dependencies.sort { $0.packageID.rawValue < $1.packageID.rawValue }

        let triggers = installedFacultyTriggers(
            templateTitle: template.title,
            sourceAbility: sourceRuntime.ability,
            sourceSkill: sourceRuntime.skill,
            operation: operation.operation)
        let eligibilityTerms = triggers.tokens.map {
            RoutingPredicate(kind: .utteranceToken, value: $0)
        } + exactBinding.targetClasses.map {
            RoutingPredicate(kind: .targetClass, value: $0)
        }
        var routing = sourceRuntime.ability.routing
        let adoptedEligibility = eligibilityTerms.isEmpty ? nil : RoutingPredicate(
            kind: .any,
            children: eligibilityTerms)
        switch (routing.eligibility, adoptedEligibility) {
        case let (.some(sourceEligibility), .some(adoptedEligibility)):
            // Adoption may narrow the source route; never replace/broaden the original eligibility.
            routing.eligibility = .init(
                kind: .all,
                children: [sourceEligibility, adoptedEligibility])
        case let (.none, .some(adoptedEligibility)):
            routing.eligibility = adoptedEligibility
        case (.some, .none), (.none, .none):
            break
        }
        routing.fallbacks = []
        routing.conflictGroup = id

        let package = MaryAbilityPackage(
            package: .init(
                id: template.packageID,
                version: "1.0.0",
                publisher: template.publisher,
                summary: template.summary,
                minimumMaryVersion: "1.0.0"),
            ability: .init(
                id: AbilityID(id),
                title: template.title,
                summary: template.summary,
                tint: template.tint,
                aliases: [],
                triggers: triggers,
                skills: [skillID],
                operatingPolicy: sourceRuntime.ability.operatingPolicy,
                routing: routing,
                paradigm: sourcePackage.paradigm,
                applications: sourceRuntime.ability.applications),
            skills: [skill],
            dependencies: dependencies)
        try requireNoErrors(AbilityPackageValidator.validate(package))
        return package
    }

    static func portableStem(
        _ value: String,
        fallback: String
    ) -> String {
        asciiWords(value).joined(separator: "-").nonEmpty ?? fallback
    }

    static func callableStem(
        _ value: String,
        fallback: String
    ) -> String {
        asciiWords(value).joined(separator: "_").nonEmpty ?? fallback
    }

    private static func asciiWords(_ value: String) -> [String] {
        var words: [String] = []
        var current = ""
        for byte in value.lowercased().utf8 {
            if (97...122).contains(byte) || (48...57).contains(byte) {
                current.append(Character(UnicodeScalar(byte)))
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func validatePackageID(_ id: PackageID) throws {
        guard SchemaIdentifierValidation.isValid(id.rawValue) else {
            throw AbilityStudioAuthoringError.invalidPackageID(id.rawValue)
        }
    }

    private static func bundleIdentifierIsValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.contains("."), value.utf8.count <= 255 else {
            return false
        }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { part in
                !part.isEmpty && part.utf8.allSatisfy { byte in
                    (48...57).contains(byte)
                        || (65...90).contains(byte)
                        || (97...122).contains(byte)
                        || byte == 45
                }
            }
    }

    private static func installedFacultyTriggers(
        templateTitle: String,
        sourceAbility: AbilitySchema,
        sourceSkill: SkillSchema,
        operation: String
    ) -> AbilityTriggerSchema {
        var triggers = sourceAbility.triggers
        let candidates = triggers.tokens
            + asciiWords(templateTitle)
            + asciiWords(sourceAbility.title)
            + asciiWords(sourceSkill.title)
            + asciiWords(operation)
        var seen = Set<String>()
        triggers.tokens = candidates.filter {
            !$0.isEmpty && $0.utf8.count <= 128 && seen.insert($0).inserted
        }.prefix(64).map { $0 }
        return triggers
    }

    static func nativeStageConstraints(
        targetClasses: [String]
    ) -> [CapabilityConstraint] {
        [
            .init(kind: .requiresStage, value: "true"),
            .init(kind: .requiresFrontmostApplication, value: "true"),
        ] + targetClasses.map {
            .init(kind: .allowedTargetClass, value: $0)
        }
    }

    private static func nativeOperatingPolicy(title: String) -> AbilityOperatingPolicy {
        .init(
            phases: ["identify-running-application", "execute-native-recipe", "verify"],
            guardrails: [
                "Never launch \(title); operate only an already-running exact bundle identity.",
                "Treat the package as data; Mary alone executes and verifies every step.",
            ],
            successSignals: ["Mary independently verified the declared postconditions"],
            stopConditions: ["user stop", "\(title) not running", "foreground identity changed"])
    }

    static func requireNoErrors(
        _ validation: AbilityPackageValidation
    ) throws {
        let errors = validation.issues.filter { $0.severity == .error }
        if !errors.isEmpty {
            throw AbilityStudioAuthoringError.invalidMutation(errors)
        }
    }
}

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

    // The installed-faculty lane is gone: the Studio teaches applications,
    // and a discipline's faculties are compiled into Mary.
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

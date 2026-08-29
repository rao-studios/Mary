//
//  PluginGraphValidator.swift
//  MaryFoundation
//
//  ADMISSION ACROSS PACKAGES: whether a Plugin operation actually satisfies
//  the Ability binding that names it, and whether the dependency edges between
//  the two packages are the ones that relationship requires.
//

import Foundation

/// Cross-package checks prove that Plugin operations satisfy actual Ability
/// bindings. Design may consume the Sketch adapter without depending on Sketch;
/// Sketch depends on Design because it imports Design's semantic schemas.
public enum PluginGraphValidator {
    public static func validate(_ packages: [MaryAbilityPackage]) -> AbilityPackageValidation {
        var issues: [SchemaIssue] = []
        func error(_ code: String, _ path: String, _ message: String) {
            issues.append(.init(severity: .error, code: code, path: path, message: message))
        }
        func warning(_ code: String, _ path: String, _ message: String) {
            issues.append(.init(severity: .warning, code: code, path: path, message: message))
        }

        let bearing = packages.compactMap { package in
            package.plugin.map { (package: package, plugin: $0) }
        }
        for duplicate in duplicates(bearing.map { $0.plugin.id }) {
            error("duplicate-plugin", "packages", "Plugin \(duplicate) is supplied more than once.")
        }
        for duplicate in duplicates(bearing.flatMap { $0.plugin.adapters.map(\.id) }) {
            error(
                "duplicate-plugin-adapter",
                "packages",
                "Plugin adapter \(duplicate.rawValue) is supplied by more than one Ability package.")
        }
        for duplicate in duplicates(bearing.map { $0.plugin.application.id }) {
            error(
                "duplicate-plugin-application",
                "packages",
                "Plugin application \(duplicate) is supplied more than once.")
        }
        for duplicate in duplicates(bearing.flatMap { $0.plugin.application.bundleIdentifiers.map { $0.lowercased() } }) {
            error(
                "duplicate-application-identity",
                "packages",
                "Bundle identifier \(duplicate) is claimed by more than one Plugin.")
        }
        // ONE LETTER, ONE MEANING. A handle prefix becomes a spoken token —
        // "[W2]" — and a person saying it expects one window. Two packages
        // minting under the same letter is experienced not as an error but as
        // Mary reaching into the wrong document. Per-package well-formedness
        // is checked in PluginValidator+ProseSurface / PluginValidator+CodeSurface;
        // only here can two packages be compared.
        //
        // BOTH FAMILIES SHARE ONE NAMESPACE. A prose surface and a code
        // surface mint the same shape of spoken handle, so a prose package's
        // "W" and a code package's "W" would collide exactly as two prose
        // packages would — checked together rather than in two separate
        // passes that could each report clean.
        for duplicate in duplicates(
            bearing.compactMap { $0.plugin.proseSurface?.handlePrefix }
                + bearing.compactMap { $0.plugin.codeSurface?.handlePrefix }) {
            error(
                "duplicate-handle-prefix",
                "packages",
                "Handle prefix \(duplicate) is minted by more than one Plugin; a spoken handle must mean one thing.")
        }
        if bearing.count > 1 {
            for leftIndex in 0..<(bearing.count - 1) {
                for rightIndex in (leftIndex + 1)..<bearing.count {
                    let left = bearing[leftIndex]
                    let right = bearing[rightIndex]
                    let leftApplication = left.plugin.application
                    let rightApplication = right.plugin.application
                    let leftExact = Set(leftApplication.bundleIdentifiers.map {
                        $0.lowercased()
                    })
                    let rightExact = Set(rightApplication.bundleIdentifiers.map {
                        $0.lowercased()
                    })
                    // Exact duplicates already have the more specific issue
                    // above. This pass is for the family capability that could
                    // otherwise shadow an exact or family-owned process.
                    guard leftExact.isDisjoint(with: rightExact) else { continue }

                    var overlaps = false
                    if let prefix = leftApplication.bundleIdentifierPrefix {
                        overlaps = rightExact.contains {
                            PluginApplicationSchema.bundleIdentifier(
                                $0,
                                isInFamily: prefix)
                        }
                    }
                    if !overlaps,
                       let prefix = rightApplication.bundleIdentifierPrefix {
                        overlaps = leftExact.contains {
                            PluginApplicationSchema.bundleIdentifier(
                                $0,
                                isInFamily: prefix)
                        }
                    }
                    if !overlaps,
                       let leftPrefix = leftApplication.bundleIdentifierPrefix,
                       let rightPrefix = rightApplication.bundleIdentifierPrefix {
                        overlaps = PluginApplicationSchema.familyPrefix(
                            leftPrefix,
                            overlaps: rightPrefix)
                    }
                    if overlaps {
                        error(
                            "overlapping-plugin-application-family",
                            "packages",
                            "Plugin applications \(left.plugin.id) and \(right.plugin.id) declare overlapping exact or family bundle identities.")
                    }
                }
            }
        }
        var routingOwners: [String: Set<String>] = [:]
        for entry in bearing {
            let application = entry.plugin.application
            let bundleTerms = application.bundleNames.flatMap { name in
                name.hasSuffix(".app")
                    ? [name, String(name.dropLast(4))]
                    : [name]
            }
            let terms = [application.id] + application.aliases + bundleTerms
            for identity in Set(terms.compactMap(normalizedRoutingIdentity)) {
                routingOwners[identity, default: []].insert(entry.plugin.id)
            }
        }
        for identity in routingOwners.keys.sorted()
        where routingOwners[identity, default: []].count > 1 {
            let owners = routingOwners[identity, default: []].sorted()
                .joined(separator: ", ")
            error(
                "duplicate-plugin-application-routing-identity",
                "packages",
                "Application routing identity \(identity) is claimed by multiple Plugins: \(owners).")
        }
        for duplicate in duplicates(bearing.flatMap { $0.plugin.operations.map(\.operation) }) {
            error(
                "duplicate-plugin-binding-operation",
                "packages",
                "Plugin binding operation \(duplicate) must be globally unique in the executable roster.")
        }

        let capabilities = Dictionary(
            packages.flatMap(\.capabilities).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let skillOwners = Dictionary(
            packages.flatMap { package in
                package.skills.map { ($0.id, (package: package, skill: $0)) }
            },
            uniquingKeysWith: { first, _ in first })
        var validRealizedSkills = Set<SkillID>()
        for entry in bearing {
            let operations = Dictionary(
                entry.plugin.operations.map { ($0.operation, $0) },
                uniquingKeysWith: { first, _ in first })
            var realizedOperations = Set<String>()
            for (realizationIndex, realization) in entry.plugin.realizations.enumerated() {
                let path = "\(entry.package.package.id.rawValue).plugin.realizations[\(realizationIndex)]"
                guard let owner = skillOwners[realization.skillID] else {
                    error(
                        "missing-plugin-realization-skill",
                        "\(path).skillID",
                        "Realized Skill \(realization.skillID.rawValue) is not installed.")
                    continue
                }
                var realizationIsValid = true
                if owner.package.package.id != entry.package.package.id,
                   !entry.package.dependencies.contains(where: {
                       $0.packageID == owner.package.package.id && !$0.optional
                   }) {
                    error(
                        "undeclared-plugin-realization-import",
                        "\(path).skillID",
                        "A Plugin must require the package that owns realized Skill \(realization.skillID.rawValue).")
                    realizationIsValid = false
                }
                guard let operation = operations[realization.operation] else { continue }
                realizedOperations.insert(operation.operation)
                let skill = owner.skill
                if requiresMutationAuthority(operation) {
                    let hasMutationAuthority = skill.requirements.capabilities
                        .compactMap { capabilities[$0]?.effect }
                        .contains(where: isMutationAuthority)
                    if !hasMutationAuthority {
                        error(
                            "plugin-input-without-mutation-authority",
                            "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).requirements.capabilities",
                            "A Plugin macUI realization that emits Remote Hands input or creates or mutates an artifact must require Capability authority of reversibleMutation or stronger.")
                        realizationIsValid = false
                    }
                }
                if skill.execution.realizationPolicy != .pluginRealizations {
                    error(
                        "realization-not-allowed",
                        "\(path).skillID",
                        "Skill \(skill.id.rawValue) does not opt into Plugin providers.")
                    realizationIsValid = false
                }
                if !skill.usesStage {
                    error(
                        "realized-skill-without-stage",
                        "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).usesStage",
                        "A Skill realized by a Plugin macUI recipe must own the stage for its full execution.")
                    realizationIsValid = false
                }
                // THE OUTPUT CONTRACT. A managed-UI recipe presses keys and
                // reports whether the press landed; the engine has no channel
                // for handing a value back. So a Skill with outputs cannot be
                // realized this way at all — it must bind to an observation
                // adapter instead, which is what a `proseSurface` declaration
                // configures. This is the rule that keeps "read my document"
                // honest rather than letting a package claim a read it cannot
                // perform.
                if !skill.outputs.isEmpty {
                    error(
                        "output-contract-unsupported",
                        "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).outputs",
                        "The managed-UI engine returns no values. A Skill with outputs must bind to an observation adapter rather than being realized by a recipe.")
                    realizationIsValid = false
                }
                let hasStageCapability = skill.requirements.capabilities.compactMap {
                    capabilities[$0]
                }.contains { capability in
                    capability.constraints.contains { $0.kind == .requiresStage && $0.value == "true" }
                }
                if !hasStageCapability {
                    error(
                        "realized-skill-missing-stage-capability",
                        "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).requirements.capabilities",
                        "A Plugin macUI Skill must require a Capability whose contract owns the stage.")
                    realizationIsValid = false
                }
                if !skill.modelExposure.parameters.isEmpty {
                    let parameters = Dictionary(
                        skill.modelExposure.parameters.map { ($0.name, $0) },
                        uniquingKeysWith: { first, _ in first })
                    for input in operation.inputs {
                        guard let parameter = parameters[input.name] else {
                            error(
                                "missing-model-input",
                                "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).modelExposure.parameters",
                                "Plugin operation input \(input.name) is absent from its realized Skill projection.")
                            realizationIsValid = false
                            continue
                        }
                        if parameter.type != input.kind.modelType {
                            error(
                                "model-input-type-mismatch",
                                "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).modelExposure.parameters",
                                "Plugin input \(input.name) expects \(input.kind.modelType), not \(parameter.type).")
                            realizationIsValid = false
                        }
                        let adapterRequiresValue = input.required
                            && input.defaultValue == nil
                        if parameter.required != adapterRequiresValue {
                            error(
                                "model-input-requiredness-mismatch",
                                "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).modelExposure.parameters",
                                "Plugin input \(input.name) and its Skill projection must agree on whether a value is required.")
                            realizationIsValid = false
                        }
                        if parameter.enumValues != input.enumValues {
                            error(
                                "model-input-enum-mismatch",
                                "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).modelExposure.parameters",
                                "Plugin input \(input.name) and its Skill projection must declare the same closed enum values.")
                            realizationIsValid = false
                        }
                    }
                    let operationInputNames = Set(operation.inputs.map(\.name))
                    for parameter in skill.modelExposure.parameters
                    where !operationInputNames.contains(parameter.name) {
                        error(
                            "extra-model-input",
                            "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).modelExposure.parameters",
                            "Skill parameter \(parameter.name) has no input in Plugin operation \(operation.operation).")
                        realizationIsValid = false
                    }
                } else if !skill.modelExposure.inheritsBindingContract && !operation.inputs.isEmpty {
                    error(
                        "hidden-plugin-operation-inputs",
                        "\(owner.package.package.id.rawValue).skills.\(skill.id.rawValue).modelExposure",
                        "A realized Plugin Skill must expose or inherit its adapter input contract.")
                    realizationIsValid = false
                }
                if realizationIsValid {
                    validRealizedSkills.insert(realization.skillID)
                }
            }
            for (operationIndex, operation) in entry.plugin.operations.enumerated()
            where !realizedOperations.contains(operation.operation) {
                error(
                    "unrealized-plugin-operation",
                    "\(entry.package.package.id.rawValue).plugin.operations[\(operationIndex)]",
                    "Plugin operation \(operation.operation) does not realize an installed Ability Skill.")
            }
        }
        for package in packages {
            for skill in package.skills
            where skill.execution.kind == .binding
                && skill.execution.bindings.isEmpty
                && skill.execution.realizationPolicy == .pluginRealizations
                && !validRealizedSkills.contains(skill.id) {
                warning(
                    "plugin-provider-unavailable",
                    "\(package.package.id.rawValue).skills.\(skill.id.rawValue).execution.bindings",
                    "No installed Plugin currently realizes this portable Skill; it will remain installed but blocked until a provider is available.")
            }
        }
        return .init(issues: issues)
    }

    private static func duplicates<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        var duplicates = Set<T>()
        for value in values where !seen.insert(value).inserted { duplicates.insert(value) }
        return Array(duplicates)
    }

    private static func requiresMutationAuthority(
        _ operation: PluginOperationSchema
    ) -> Bool {
        let emitsInput = (operation.steps + operation.cleanupSteps).contains {
            ![.wait, .rebindFocusedWindow, .captureAccessibilityAnchor]
                .contains($0.kind)
        }
        let mutatesArtifact = operation.semantics.map {
            [.createArtifact, .mutateArtifact].contains($0.role)
        } ?? false
        return emitsInput || mutatesArtifact
    }

    private static func isMutationAuthority(_ effect: CapabilityEffect) -> Bool {
        switch effect {
        case .none, .read:
            false
        case .reversibleMutation, .mutation, .destructive, .externalCommunication:
            true
        }
    }

    private static func normalizedRoutingIdentity(_ value: String) -> String? {
        let identity = value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
        return identity.isEmpty ? nil : identity
    }
}

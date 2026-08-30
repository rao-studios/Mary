//
//  AbilityPackageValidator+Graph.swift
//  MaryFoundation
//
//  WHAT: Cross-package admission — unique owners, invocation names, deps, no required cycles.
//  IN:   installed [MaryAbilityPackage].
//  OUT:  AbilityPackageValidation; PluginGraphValidator for Plugin edges.
//

import Foundation

extension AbilityPackageValidator {
    public static func validateGraph(
        _ packages: [MaryAbilityPackage]
    ) -> AbilityPackageValidation {
        var issues = packages.flatMap { validate($0).issues }
        issues.append(contentsOf: PluginGraphValidator.validate(packages).issues)
        let byID = Dictionary(grouping: packages, by: { $0.package.id })
        for (id, versions) in byID where versions.count > 1 {
            issues.append(.init(
                severity: .error,
                code: "duplicate-package",
                path: "packages",
                message: "More than one active package exports \(id.rawValue)."))
        }

        func graphError(_ code: String, _ path: String, _ message: String) {
            issues.append(.init(severity: .error, code: code, path: path, message: message))
        }

        /// One active owner per portable schema id. Resolve by id, not file order.
        func schemaOwners(
            _ exports: [(id: String, owner: PackageID)],
            kind: String
        ) -> [String: PackageID] {
            var result: [String: PackageID] = [:]
            for export in exports {
                if let previous = result[export.id], previous != export.owner {
                    graphError(
                        "duplicate-schema-export",
                        "\(export.owner.rawValue).\(kind)",
                        "\(kind) schema \(export.id) is already owned by \(previous.rawValue); active schema ids have one package owner.")
                } else {
                    result[export.id] = export.owner
                }
            }
            return result
        }

        let valueOwners = schemaOwners(packages.flatMap { package in
            package.valueTypes.map { ($0.id.rawValue, package.package.id) }
        }, kind: "value-type")
        let capabilityOwners = schemaOwners(packages.flatMap { package in
            package.capabilities.map { ($0.id.rawValue, package.package.id) }
        }, kind: "capability")
        let interactionOwners = schemaOwners(packages.flatMap { package in
            package.interactions.map { ($0.id.rawValue, package.package.id) }
        }, kind: "interaction")
        let perceptionOwners = schemaOwners(packages.flatMap { package in
            package.perceptions.map { ($0.id.rawValue, package.package.id) }
        }, kind: "perception")
        _ = schemaOwners(packages.flatMap { package in
            package.skills.map { ($0.id.rawValue, package.package.id) }
        }, kind: "skill")
        _ = schemaOwners(packages.flatMap { package in
            package.totemProjections.map { ($0.id.rawValue, package.package.id) }
        }, kind: "totem-projection")

        let abilityIDs = Set(packages.map(\.ability.id))
        let abilityOwners = Dictionary(
            packages.map { ($0.ability.id.rawValue, $0.package.id) },
            uniquingKeysWith: { first, _ in first })

        func checkOwnedReference(
            _ id: String,
            kind: String,
            owners: [String: PackageID],
            consumer: MaryAbilityPackage,
            path: String,
            missingCode: String
        ) {
            guard let owner = owners[id] else {
                graphError(
                    missingCode,
                    path,
                    "\(kind) schema \(id) is not supplied by the installed package graph.")
                return
            }
            guard owner != consumer.package.id else { return }
            guard consumer.dependencies.contains(where: { $0.packageID == owner }) else {
                graphError(
                    "undeclared-schema-import",
                    path,
                    "\(consumer.package.id.rawValue) references \(kind) schema \(id), owned by \(owner.rawValue), without declaring that package dependency.")
                return
            }
        }

        func checkPredicateReferences(
            _ predicate: RoutingPredicate,
            consumer: MaryAbilityPackage,
            path: String
        ) {
            if let value = predicate.value {
                switch predicate.kind {
                case .hasCapability:
                    checkOwnedReference(
                        value, kind: "Capability", owners: capabilityOwners,
                        consumer: consumer, path: path,
                        missingCode: "missing-routing-capability")
                case .hasInteraction:
                    checkOwnedReference(
                        value, kind: "Interaction", owners: interactionOwners,
                        consumer: consumer, path: path,
                        missingCode: "missing-routing-interaction")
                case .hasPerception:
                    checkOwnedReference(
                        value, kind: "Perception", owners: perceptionOwners,
                        consumer: consumer, path: path,
                        missingCode: "missing-routing-perception")
                default: break
                }
            }
            for (index, child) in predicate.children.enumerated() {
                checkPredicateReferences(
                    child,
                    consumer: consumer,
                    path: "\(path).children[\(index)]")
            }
        }

        var invocationOwners: [String: (PackageID, SkillID)] = [:]
        for package in packages {
            let packagePath = package.package.id.rawValue
            for (valueIndex, value) in package.valueTypes.enumerated() {
                if let item = value.itemType {
                    checkOwnedReference(
                        item.rawValue, kind: "Value Type", owners: valueOwners,
                        consumer: package,
                        path: "\(packagePath).valueTypes[\(valueIndex)].itemType",
                        missingCode: "missing-value-type")
                }
                for (fieldIndex, field) in value.fields.enumerated() {
                    checkOwnedReference(
                        field.valueType.rawValue, kind: "Value Type", owners: valueOwners,
                        consumer: package,
                        path: "\(packagePath).valueTypes[\(valueIndex)].fields[\(fieldIndex)].valueType",
                        missingCode: "missing-value-type")
                }
            }
            for (capabilityIndex, capability) in package.capabilities.enumerated() {
                if let input = capability.inputType {
                    checkOwnedReference(
                        input.rawValue, kind: "Value Type", owners: valueOwners,
                        consumer: package,
                        path: "\(packagePath).capabilities[\(capabilityIndex)].inputType",
                        missingCode: "missing-value-type")
                }
                if let output = capability.outputType {
                    checkOwnedReference(
                        output.rawValue, kind: "Value Type", owners: valueOwners,
                        consumer: package,
                        path: "\(packagePath).capabilities[\(capabilityIndex)].outputType",
                        missingCode: "missing-value-type")
                }
            }
            for (interactionIndex, interaction) in package.interactions.enumerated() {
                checkOwnedReference(
                    interaction.valueType.rawValue, kind: "Value Type", owners: valueOwners,
                    consumer: package,
                    path: "\(packagePath).interactions[\(interactionIndex)].valueType",
                    missingCode: "missing-value-type")
            }
            for (perceptionIndex, perception) in package.perceptions.enumerated() {
                checkOwnedReference(
                    perception.valueType.rawValue, kind: "Value Type", owners: valueOwners,
                    consumer: package,
                    path: "\(packagePath).perceptions[\(perceptionIndex)].valueType",
                    missingCode: "missing-value-type")
            }
            if let predicate = package.ability.routing.eligibility {
                checkPredicateReferences(
                    predicate, consumer: package,
                    path: "\(packagePath).ability.routing.eligibility")
            }
            for (index, predicate) in package.ability.routing.excludes.enumerated() {
                checkPredicateReferences(
                    predicate, consumer: package,
                    path: "\(packagePath).ability.routing.excludes[\(index)]")
            }
            for (skillIndex, skill) in package.skills.enumerated() {
                if let name = skill.invocationName {
                    if let previous = invocationOwners[name] {
                        issues.append(.init(
                            severity: .error,
                            code: "duplicate-invocation",
                            path: "\(package.package.id.rawValue).skills.\(skill.id.rawValue)",
                            message: "Invocation \(name) is already owned by \(previous.0.rawValue)/\(previous.1.rawValue)."))
                    } else {
                        invocationOwners[name] = (package.package.id, skill.id)
                    }
                }
                for (portIndex, port) in skill.inputs.enumerated() {
                    checkOwnedReference(
                        port.valueType.rawValue, kind: "Value Type", owners: valueOwners,
                        consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].inputs[\(portIndex)].valueType",
                        missingCode: "missing-value-type")
                }
                for (portIndex, port) in skill.outputs.enumerated() {
                    checkOwnedReference(
                        port.valueType.rawValue, kind: "Value Type", owners: valueOwners,
                        consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].outputs[\(portIndex)].valueType",
                        missingCode: "missing-value-type")
                }
                for ability in skill.requirements.supportingAbilities {
                    let path = "\(packagePath).skills[\(skillIndex)].requirements.supportingAbilities"
                    guard abilityIDs.contains(ability),
                          let owner = abilityOwners[ability.rawValue]
                    else {
                        graphError(
                            "missing-supporting-ability", path,
                            "Supporting Ability \(ability.rawValue) is not installed.")
                        continue
                    }
                    if owner != package.package.id,
                       !package.dependencies.contains(where: { $0.packageID == owner }) {
                        graphError(
                            "undeclared-ability-dependency", path,
                            "Supporting Ability \(ability.rawValue) must be named in package dependencies.")
                    }
                }
                for capability in skill.requirements.capabilities {
                    checkOwnedReference(
                        capability.rawValue, kind: "Capability", owners: capabilityOwners,
                        consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].requirements.capabilities",
                        missingCode: "missing-capability")
                }
                for interaction in skill.requirements.interactions {
                    checkOwnedReference(
                        interaction.rawValue, kind: "Interaction", owners: interactionOwners,
                        consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].requirements.interactions",
                        missingCode: "missing-interaction")
                }
                for perception in skill.requirements.perceptions {
                    checkOwnedReference(
                        perception.rawValue, kind: "Perception", owners: perceptionOwners,
                        consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].requirements.perceptions",
                        missingCode: "missing-perception")
                }
                for interaction in skill.requirements.optionalInteractions {
                    checkOwnedReference(
                        interaction.rawValue, kind: "Interaction", owners: interactionOwners,
                        consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].requirements.optionalInteractions",
                        missingCode: "missing-optional-interaction")
                }
                for perception in skill.requirements.optionalPerceptions {
                    checkOwnedReference(
                        perception.rawValue, kind: "Perception", owners: perceptionOwners,
                        consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].requirements.optionalPerceptions",
                        missingCode: "missing-optional-perception")
                }
                if let predicate = skill.routing.eligibility {
                    checkPredicateReferences(
                        predicate, consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].routing.eligibility")
                }
                for (predicateIndex, predicate) in skill.routing.excludes.enumerated() {
                    checkPredicateReferences(
                        predicate, consumer: package,
                        path: "\(packagePath).skills[\(skillIndex)].routing.excludes[\(predicateIndex)]")
                }
            }
            for (fixtureIndex, fixture) in package.fixtures.enumerated() {
                for interaction in fixture.interactions {
                    checkOwnedReference(
                        interaction.rawValue, kind: "Interaction", owners: interactionOwners,
                        consumer: package,
                        path: "\(packagePath).fixtures[\(fixtureIndex)].interactions",
                        missingCode: "missing-fixture-interaction")
                }
            }
            for dependency in package.dependencies {
                guard let installed = byID[dependency.packageID]?.first else {
                    if !dependency.optional {
                        issues.append(.init(
                            severity: .error,
                            code: "missing-dependency",
                            path: "\(package.package.id.rawValue).dependencies",
                            message: "Required package \(dependency.packageID.rawValue) is not installed."))
                    }
                    continue
                }
                if installed.package.version < dependency.minimumVersion {
                    issues.append(.init(
                        severity: .error,
                        code: "dependency-version",
                        path: "\(package.package.id.rawValue).dependencies",
                        message: "\(dependency.packageID.rawValue) must be at least \(dependency.minimumVersion.rawValue)."))
                }
            }
        }

        // Required cycles cannot install. Optional collaboration edges skip this.
        let requiredEdges = Dictionary(uniqueKeysWithValues: packages.map { package in
            (package.package.id, package.dependencies.filter { !$0.optional }.map(\.packageID))
        })
        var visiting: Set<PackageID> = []
        var visited: Set<PackageID> = []
        func visit(_ id: PackageID, trail: [PackageID]) {
            if visiting.contains(id) {
                let cycle = (trail + [id]).map(\.rawValue).joined(separator: " -> ")
                graphError("dependency-cycle", "packages", "Required Ability package dependency cycle: \(cycle).")
                return
            }
            guard visited.insert(id).inserted else { return }
            visiting.insert(id)
            for next in requiredEdges[id] ?? [] where byID[next] != nil {
                visit(next, trail: trail + [id])
            }
            visiting.remove(id)
        }
        for id in requiredEdges.keys { visit(id, trail: []) }
        return AbilityPackageValidation(issues: issues)
    }
}

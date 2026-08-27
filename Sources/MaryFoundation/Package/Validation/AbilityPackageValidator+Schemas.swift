//
//  AbilityPackageValidator+Schemas.swift
//  MaryFoundation
//
//  THE SCHEMAS A PACKAGE DECLARES — Capabilities, Interactions, Perceptions,
//  Value Types, and Totem projections — checked first for internal
//  well-formedness and then for whether every id they point at resolves to
//  something this package owns or a dependency must supply.
//

import Foundation

extension AbilityPackageValidator {
    static func validateDeclaredSchemas(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        let supplied = Set(package.skills.map(\.id))
        validateUnique(package.capabilities.map { ($0.id.rawValue, "capabilities") }, code: "duplicate-capability", issues: &sink.issues)
        validateUnique(package.interactions.map { ($0.id.rawValue, "interactions") }, code: "duplicate-interaction", issues: &sink.issues)
        validateUnique(package.perceptions.map { ($0.id.rawValue, "perceptions") }, code: "duplicate-perception", issues: &sink.issues)
        validateUnique(package.valueTypes.map { ($0.id.rawValue, "valueTypes") }, code: "duplicate-value-type", issues: &sink.issues)
        validateUnique(package.totemProjections.map { ($0.id.rawValue, "totemProjections") }, code: "duplicate-projection", issues: &sink.issues)

        package.capabilities.enumerated().forEach { index, value in
            let path = "capabilities[\(index)]"
            sink.checkID(value.id.rawValue, "\(path).id")
            if !semanticVersionIsValid(value.version.rawValue) {
                sink.error("invalid-version", "\(path).version", "Use semantic versioning such as 1.0.0.")
            }
            sink.checkText(value.title, "\(path).title", "capability-title")
            sink.checkText(value.summary, "\(path).summary", "capability-summary")
            duplicates(value.permissions.map { "\($0.kind.rawValue)|\($0.target ?? "")" }).forEach {
                sink.error("duplicate-permission", "\(path).permissions", "Permission requirement \($0) appears more than once.")
            }
            for (permissionIndex, permission) in value.permissions.enumerated() {
                sink.checkText(permission.reason, "\(path).permissions[\(permissionIndex)].reason", "permission-reason")
            }
            duplicates(value.constraints.map { "\($0.kind.rawValue)|\($0.value)" }).forEach {
                sink.error("duplicate-capability-constraint", "\(path).constraints", "Capability constraint \($0) appears more than once.")
            }
            for (constraintIndex, constraint) in value.constraints.enumerated() {
                let constraintPath = "\(path).constraints[\(constraintIndex)]"
                switch constraint.kind {
                case .maximumDurationSeconds:
                    guard let seconds = Double(constraint.value),
                          seconds.isFinite,
                          seconds > 0
                    else {
                        sink.error(
                            "invalid-duration-constraint",
                            "\(constraintPath).value",
                            "A maximum duration must be a finite number greater than zero.")
                        continue
                    }
                case .maximumPayloadBytes:
                    guard let bytes = Int(constraint.value), bytes > 0 else {
                        sink.error(
                            "invalid-payload-constraint",
                            "\(constraintPath).value",
                            "A maximum payload must be a positive base-10 byte count that fits this runtime.")
                        continue
                    }
                case .requiresFrontmostApplication,
                     .requiresStableDocumentIdentity,
                     .requiresUserConfirmation,
                     .requiresStage,
                     .sourceMustMatchTarget,
                     .allowedTargetClass:
                    if !machineTokenIsValid(constraint.value) {
                        sink.error(
                            "invalid-constraint-token",
                            "\(constraintPath).value",
                            "Constraint values must be bounded lower-case machine tokens, not prose.")
                    }
                }
            }
        }
        package.interactions.enumerated().forEach { index, value in
            let path = "interactions[\(index)]"
            sink.checkID(value.id.rawValue, "\(path).id")
            sink.checkID(value.valueType.rawValue, "\(path).valueType")
            if !semanticVersionIsValid(value.version.rawValue) {
                sink.error("invalid-version", "\(path).version", "Use semantic versioning such as 1.0.0.")
            }
            sink.checkText(value.title, "\(path).title", "interaction-title")
            sink.checkText(value.summary, "\(path).summary", "interaction-summary")
            if !value.freshnessSeconds.isFinite || value.freshnessSeconds <= 0 {
                sink.error("invalid-freshness", "\(path).freshnessSeconds", "Interaction freshness must be finite and greater than zero.")
            }
            if value.supersessionKeys.isEmpty {
                sink.error("missing-supersession-key", "\(path).supersessionKeys", "An Interaction must declare how a newer source value supersedes it.")
            }
            duplicates(value.supersessionKeys).forEach {
                sink.error("duplicate-supersession-key", "\(path).supersessionKeys", "Supersession key \($0) appears more than once.")
            }
            let sourceScopeKeys: Set<String> = [
                "deviceID", "applicationID", "processID", "processEpoch",
                "activationSequence", "windowID", "workspaceID", "projectID",
                "documentID", "surfaceID",
            ]
            for (keyIndex, key) in value.supersessionKeys.enumerated()
            where !sourceScopeKeys.contains(key) {
                sink.error(
                    "unknown-supersession-key",
                    "\(path).supersessionKeys[\(keyIndex)]",
                    "Supersession keys must name a SourceScope field.")
            }
            if value.clearPolicies.isEmpty {
                sink.error("missing-clear-policy", "\(path).clearPolicies", "An Interaction must declare at least one clear policy.")
            }
            if Set(value.clearPolicies).count != value.clearPolicies.count {
                sink.error("duplicate-clear-policy", "\(path).clearPolicies", "An Interaction clear policy may appear only once.")
            }
            if value.evidence.isEmpty {
                sink.error("missing-interaction-evidence", "\(path).evidence", "An Interaction must declare at least one evidence channel.")
            }
            duplicates(value.evidence.map(\.channel)).forEach {
                sink.error("duplicate-evidence-channel", "\(path).evidence", "Evidence channel \($0) appears more than once.")
            }
            for (evidenceIndex, evidence) in value.evidence.enumerated() {
                sink.checkText(evidence.channel, "\(path).evidence[\(evidenceIndex)].channel", "evidence-channel")
                if evidence.rank < 0 {
                    sink.error("invalid-evidence-rank", "\(path).evidence[\(evidenceIndex)].rank", "Evidence rank cannot be negative.")
                }
            }
            if value.requiredScope.isEmpty {
                sink.error("missing-required-scope", "\(path).requiredScope", "An Interaction must declare at least one acceptable source resolution.")
            }
            if Set(value.requiredScope).count != value.requiredScope.count {
                sink.error("duplicate-required-scope", "\(path).requiredScope", "A required source resolution may appear only once.")
            }
        }
        package.perceptions.enumerated().forEach { index, value in
            let path = "perceptions[\(index)]"
            sink.checkID(value.id.rawValue, "\(path).id")
            sink.checkID(value.valueType.rawValue, "\(path).valueType")
            if !semanticVersionIsValid(value.version.rawValue) {
                sink.error("invalid-version", "\(path).version", "Use semantic versioning such as 1.0.0.")
            }
            sink.checkText(value.title, "\(path).title", "perception-title")
            sink.checkText(value.summary, "\(path).summary", "perception-summary")
            if !value.freshnessSeconds.isFinite || value.freshnessSeconds <= 0 {
                sink.error("invalid-freshness", "\(path).freshnessSeconds", "Perception freshness must be finite and greater than zero.")
            }
        }
        package.valueTypes.enumerated().forEach { index, value in
            let path = "valueTypes[\(index)]"
            sink.checkID(value.id.rawValue, "\(path).id")
            if !semanticVersionIsValid(value.version.rawValue) {
                sink.error("invalid-version", "\(path).version", "Use semantic versioning such as 1.0.0.")
            }
            sink.checkText(value.title, "\(path).title", "value-type-title")
            sink.checkText(value.summary, "\(path).summary", "value-type-summary")
            duplicates(value.fields.map(\.name)).forEach {
                sink.error("duplicate-value-field", "\(path).fields", "Value field \($0) appears more than once.")
            }
            for (fieldIndex, field) in value.fields.enumerated() {
                sink.checkText(field.name, "\(path).fields[\(fieldIndex)].name", "field-name")
                sink.checkText(field.summary, "\(path).fields[\(fieldIndex)].summary", "field-summary")
            }
            switch value.shape {
            case .object:
                if value.itemType != nil || !value.enumValues.isEmpty {
                    sink.error("value-shape-mismatch", path, "Object value types use fields, not itemType or enumValues.")
                }
            case .array:
                if value.itemType == nil {
                    sink.error("missing-array-item-type", "\(path).itemType", "An array value type must name its item type.")
                }
                if !value.fields.isEmpty || !value.enumValues.isEmpty {
                    sink.error("value-shape-mismatch", path, "Array value types use itemType, not fields or enumValues.")
                }
            case .enumeration:
                if value.enumValues.isEmpty {
                    sink.error("missing-enum-values", "\(path).enumValues", "An enumeration must declare at least one value.")
                }
                if !value.fields.isEmpty || value.itemType != nil {
                    sink.error("value-shape-mismatch", path, "Enumeration value types use enumValues, not fields or itemType.")
                }
                duplicates(value.enumValues).forEach {
                    sink.error("duplicate-enum-value", "\(path).enumValues", "Enum value \($0) appears more than once.")
                }
            default:
                if !value.fields.isEmpty || value.itemType != nil || !value.enumValues.isEmpty {
                    sink.error("value-shape-mismatch", path, "Scalar value types cannot declare fields, itemType, or enumValues.")
                }
            }
        }
        package.totemProjections.enumerated().forEach { index, value in
            let path = "totemProjections[\(index)]"
            sink.checkID(value.id.rawValue, "\(path).id")
            if !semanticVersionIsValid(value.version.rawValue) {
                sink.error("invalid-version", "\(path).version", "Use semantic versioning such as 1.0.0.")
            }
            if value.lanes.isEmpty && value.persistence != .none {
                sink.error("missing-totem-lane", "\(path).lanes", "A persisted Totem projection must name at least one lane.")
            }
            if let retention = value.retentionSeconds,
               (!retention.isFinite || retention <= 0) {
                sink.error("invalid-retention", "\(path).retentionSeconds", "Projection retention must be a finite number greater than zero.")
            }
            duplicates(value.skills.map(\.rawValue)).forEach {
                sink.error("duplicate-projection-skill", "\(path).skills", "Skill selector \($0) appears more than once.")
            }
            duplicates(value.lanes.map(\.rawValue)).forEach {
                sink.error("duplicate-totem-lane", "\(path).lanes", "Totem lane \($0) appears more than once.")
            }
            duplicates(value.include).forEach {
                sink.error("duplicate-projection-field", "\(path).include", "Projected field \($0) appears more than once.")
            }
            duplicates(value.exclude).forEach {
                sink.error("duplicate-projection-field", "\(path).exclude", "Excluded field \($0) appears more than once.")
            }
            for (skillIndex, skill) in value.skills.enumerated() {
                sink.checkID(skill.rawValue, "\(path).skills[\(skillIndex)]")
                if !supplied.contains(skill) {
                    sink.error(
                        "missing-projection-skill",
                        "\(path).skills[\(skillIndex)]",
                        "Projection selector \(skill.rawValue) is not a Skill in this Ability.")
                }
            }
            for (fieldIndex, field) in value.include.enumerated() where field.isEmpty {
                sink.error("empty-projection-field", "\(path).include[\(fieldIndex)]", "Projected field names cannot be empty.")
            }
            for (fieldIndex, field) in value.exclude.enumerated() where field.isEmpty {
                sink.error("empty-projection-field", "\(path).exclude[\(fieldIndex)]", "Excluded field names cannot be empty.")
            }
            let overlap = Set(value.include).intersection(value.exclude)
            for field in overlap {
                sink.error("projection-include-exclude-conflict", path, "Projection field \(field) cannot be both included and excluded.")
            }
            if value.purpose == .interaction {
                if !value.skills.isEmpty {
                    sink.error(
                        "interaction-projection-selects-skills",
                        "\(path).skills",
                        "Interaction projections are selected by Interaction schemas, not Skills.")
                }
                if value.persistence == .durable {
                    sink.error(
                        "durable-interaction-projection",
                        "\(path).persistence",
                        "Source-owned Interaction projections may be none or session scoped, never durable.")
                }
            }
        }
    }

    /// Value Types referenced but not owned here are a dependency's to supply;
    /// Totem projections must be selected by exactly the kind of declaration
    /// their purpose allows.
    static func validateSchemaReferences(
        _ package: MaryAbilityPackage,
        _ sink: PackageIssueSink
    ) {
        let localValueTypes = Set(package.valueTypes.map(\.id))
        func noteExternalValue(_ id: ValueTypeID?, _ path: String) {
            guard let id else { return }
            if !localValueTypes.contains(id) {
                sink.warning(
                    "external-value-type",
                    path,
                    "Value Type \(id.rawValue) must resolve to the unique owner named by a package dependency when this package is validated in an Ability graph.")
            }
        }
        for (index, value) in package.valueTypes.enumerated() {
            noteExternalValue(value.itemType, "valueTypes[\(index)].itemType")
            for (fieldIndex, field) in value.fields.enumerated() {
                noteExternalValue(field.valueType, "valueTypes[\(index)].fields[\(fieldIndex)].valueType")
            }
        }
        for (index, capability) in package.capabilities.enumerated() {
            noteExternalValue(capability.inputType, "capabilities[\(index)].inputType")
            noteExternalValue(capability.outputType, "capabilities[\(index)].outputType")
        }
        for (index, interaction) in package.interactions.enumerated() {
            noteExternalValue(interaction.valueType, "interactions[\(index)].valueType")
        }
        for (index, perception) in package.perceptions.enumerated() {
            noteExternalValue(perception.valueType, "perceptions[\(index)].valueType")
        }
        for (skillIndex, skill) in package.skills.enumerated() {
            for (portIndex, port) in skill.inputs.enumerated() {
                noteExternalValue(port.valueType, "skills[\(skillIndex)].inputs[\(portIndex)].valueType")
            }
            for (portIndex, port) in skill.outputs.enumerated() {
                noteExternalValue(port.valueType, "skills[\(skillIndex)].outputs[\(portIndex)].valueType")
            }
        }

        let projectionIDs = Set(package.totemProjections.map(\.id))
        let abilityProjectionIDs = Set(package.ability.totemProjections)
        let interactionProjectionIDs = Set(package.interactions.compactMap(\.totemProjection))
        for projection in package.ability.totemProjections where !projectionIDs.contains(projection) {
            sink.error("missing-projection-schema", "ability.totemProjections", "No Totem projection schema was supplied for \(projection.rawValue).")
        }
        for (index, interaction) in package.interactions.enumerated() {
            if let projection = interaction.totemProjection,
               !projectionIDs.contains(projection) {
                sink.error("missing-projection-schema", "interactions[\(index)].totemProjection", "No Totem projection schema was supplied for \(projection.rawValue).")
            }
        }
        for (index, projection) in package.totemProjections.enumerated() {
            let path = "totemProjections[\(index)]"
            switch projection.purpose {
            case .receipt, .content:
                if !abilityProjectionIDs.contains(projection.id) {
                    sink.error(
                        "unselected-skill-projection",
                        path,
                        "Receipt and content projections must be selected by ability.totemProjections.")
                }
                if interactionProjectionIDs.contains(projection.id) {
                    sink.error(
                        "skill-projection-used-for-interaction",
                        path,
                        "An Interaction cannot select a receipt or content projection.")
                }
            case .interaction:
                if abilityProjectionIDs.contains(projection.id) {
                    sink.error(
                        "interaction-projection-used-for-skill",
                        path,
                        "An Ability cannot select an Interaction projection for Skill persistence.")
                }
                if !interactionProjectionIDs.contains(projection.id) {
                    sink.error(
                        "unselected-interaction-projection",
                        path,
                        "Interaction projections must be selected by an Interaction schema.")
                }
            }
        }
    }
}

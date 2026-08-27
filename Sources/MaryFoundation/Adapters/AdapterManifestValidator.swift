//
//  AdapterManifestValidator.swift
//  MaryFoundation
//
//  Admission for an installed adapter manifest, checked against the packages
//  it claims to serve — the machine-local half of the graph that package
//  validation cannot see.
//

import Foundation

/// Validation result for the machine-local half of Mary's schema join.
/// Adapter manifests are not part of a shared `.mary` package, but their
/// identifiers and claims need the same deterministic scrutiny before the
/// runtime can rely on them.
public struct AdapterManifestValidation: Codable, Hashable, Sendable {
    public var issues: [SchemaIssue]
    public var isValid: Bool { !issues.contains { $0.severity == .error } }

    public init(issues: [SchemaIssue] = []) {
        self.issues = issues
    }
}

public enum AdapterManifestValidator {
    public static func validate(_ manifest: InstalledAdapterManifest) -> AdapterManifestValidation {
        validate([manifest])
    }

    /// Validates the complete installed inventory. Adapter IDs are unique at
    /// this boundary: an availability update replaces a manifest instead of
    /// adding a second, ambiguous claim for the same executable adapter.
    public static func validate(_ manifests: [InstalledAdapterManifest]) -> AdapterManifestValidation {
        var issues: [SchemaIssue] = []
        func error(_ code: String, _ path: String, _ message: String) {
            issues.append(.init(severity: .error, code: code, path: path, message: message))
        }
        func warning(_ code: String, _ path: String, _ message: String) {
            issues.append(.init(severity: .warning, code: code, path: path, message: message))
        }
        func checkIDs<ID: SchemaIdentifier>(_ values: [ID], path: String) {
            for (index, value) in values.enumerated()
            where !SchemaIdentifierValidation.isValid(value.rawValue) {
                error(
                    "invalid-adapter-claim-id",
                    "\(path)[\(index)]",
                    "Adapter claims use lower-case portable schema identifiers.")
            }
            for duplicate in duplicates(values.map(\.rawValue)) {
                error(
                    "duplicate-adapter-claim",
                    path,
                    "Adapter claim \(duplicate) appears more than once.")
            }
        }

        for duplicate in duplicates(manifests.map { $0.adapterID.rawValue }) {
            error(
                "duplicate-adapter-manifest",
                "adapterManifests",
                "Installed adapter \(duplicate) published more than one manifest.")
        }

        for (manifestIndex, manifest) in manifests.enumerated() {
            let path = "adapterManifests[\(manifestIndex)]"
            if !SchemaIdentifierValidation.isValid(manifest.adapterID.rawValue) {
                error(
                    "invalid-adapter-id",
                    "\(path).adapterID",
                    "Use a lower-case portable adapter identifier containing letters, numbers, dots, or hyphens.")
            }
            if !semanticVersionIsValid(manifest.version.rawValue) {
                error(
                    "invalid-adapter-version",
                    "\(path).version",
                    "Use semantic versioning such as 1.0.0 or 1.0.0-beta.1.")
            }
            if manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error("missing-adapter-title", "\(path).title", "Every installed adapter needs a title.")
            }
            if manifest.transport == .bluetooth,
               manifest.claimCoverage != .complete {
                error(
                    "incomplete-bluetooth-contract",
                    "\(path).claimCoverage",
                    "Bluetooth adapters must publish a complete typed contract before Mary accepts device data.")
            }
            checkAvailability(
                manifest.isAvailable,
                reason: manifest.unavailableReason,
                path: path,
                noun: "adapter",
                error: error,
                warning: warning)

            for duplicate in duplicates(manifest.operations.map(\.operation)) {
                error(
                    "duplicate-adapter-operation",
                    "\(path).operations",
                    "Operation \(duplicate) appears more than once in this adapter manifest.")
            }
            checkIDs(manifest.providesInteractions, path: "\(path).providesInteractions")
            checkIDs(manifest.providesPerceptions, path: "\(path).providesPerceptions")
            checkIDs(manifest.supportedValueTypes, path: "\(path).supportedValueTypes")
            if Set(manifest.grantedPermissions).count != manifest.grantedPermissions.count {
                error(
                    "duplicate-adapter-permission",
                    "\(path).grantedPermissions",
                    "An adapter permission may be declared only once.")
            }

            for (operationIndex, operation) in manifest.operations.enumerated() {
                let operationPath = "\(path).operations[\(operationIndex)]"
                if operation.adapterID != manifest.adapterID {
                    error(
                        "adapter-operation-owner-mismatch",
                        "\(operationPath).adapterID",
                        "Operation \(operation.operation) must name its enclosing adapter \(manifest.adapterID.rawValue).")
                }
                if !callableNameIsValid(operation.operation) {
                    error(
                        "invalid-adapter-operation",
                        "\(operationPath).operation",
                        "Adapter operation names use lower-case snake_case.")
                }
                checkIDs(operation.capabilities, path: "\(operationPath).capabilities")
                checkIDs(operation.inputTypes, path: "\(operationPath).inputTypes")
                checkIDs(operation.outputTypes, path: "\(operationPath).outputTypes")
                checkIDs(operation.consumesInteractions, path: "\(operationPath).consumesInteractions")
                checkIDs(operation.observesPerceptions, path: "\(operationPath).observesPerceptions")
                for (targetIndex, target) in operation.targetClasses.enumerated() {
                    if !SchemaIdentifierValidation.isValid(target) {
                        error(
                            "invalid-adapter-target-class",
                            "\(operationPath).targetClasses[\(targetIndex)]",
                            "Adapter target classes use lower-case portable identifiers.")
                    }
                }
                for duplicate in duplicates(operation.targetClasses) {
                    error(
                        "duplicate-adapter-target-class",
                        "\(operationPath).targetClasses",
                        "Target class \(duplicate) appears more than once.")
                }
                for duplicate in duplicates(operation.enforcedConstraints.map {
                    "\($0.kind.rawValue)|\($0.value)"
                }) {
                    error(
                        "duplicate-enforced-constraint",
                        "\(operationPath).enforcedConstraints",
                        "Enforced constraint \(duplicate) appears more than once.")
                }
                let delegatedKinds: Set<CapabilityConstraint.Kind> = [
                    .requiresFrontmostApplication,
                    .requiresStableDocumentIdentity,
                    .sourceMustMatchTarget,
                ]
                for (constraintIndex, constraint) in operation.enforcedConstraints.enumerated() {
                    let constraintPath = "\(operationPath).enforcedConstraints[\(constraintIndex)]"
                    if !delegatedKinds.contains(constraint.kind) {
                        error(
                            "runtime-owned-enforced-constraint",
                            "\(constraintPath).kind",
                            "Adapters may attest only frontmost-application, stable-document, and source-target guarantees; Mary enforces all other constraint kinds.")
                    }
                    if !machineTokenIsValid(constraint.value) {
                        error(
                            "invalid-enforced-constraint-value",
                            "\(constraintPath).value",
                            "Adapter constraint values must be bounded lower-case machine tokens.")
                    }
                }
                checkAvailability(
                    operation.isAvailable,
                    reason: operation.unavailableReason,
                    path: operationPath,
                    noun: "adapter operation",
                    error: error,
                    warning: warning)

                let supportedValues = Set(manifest.supportedValueTypes)
                if manifest.claimCoverage == .complete || !supportedValues.isEmpty {
                    for unsupported in Set(operation.inputTypes + operation.outputTypes)
                        .subtracting(supportedValues) {
                        error(
                            "operation-value-outside-manifest",
                            operationPath,
                            "Operation \(operation.operation) claims Value type \(unsupported.rawValue), but its adapter does not list that type as supported.")
                    }
                }
            }
        }
        return AdapterManifestValidation(issues: issues)
    }

    private static func checkAvailability(
        _ isAvailable: Bool,
        reason: String?,
        path: String,
        noun: String,
        error: (String, String, String) -> Void,
        warning: (String, String, String) -> Void
    ) {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !isAvailable && trimmed.isEmpty {
            error(
                "missing-unavailable-reason",
                "\(path).unavailableReason",
                "An unavailable \(noun) must explain why it cannot participate.")
        } else if isAvailable && !trimmed.isEmpty {
            warning(
                "stale-unavailable-reason",
                "\(path).unavailableReason",
                "An available \(noun) should not retain an unavailable reason.")
        }
    }

    private static func semanticVersionIsValid(_ value: String) -> Bool {
        value.range(
            of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
            options: .regularExpression) != nil
    }

    private static func callableNameIsValid(_ value: String) -> Bool {
        value.range(
            of: #"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"#,
            options: .regularExpression) != nil
    }

    private static func machineTokenIsValid(_ value: String) -> Bool {
        value.count <= 96 && value.range(
            of: #"^[a-z0-9]+(?:[._-][a-z0-9]+)*$"#,
            options: .regularExpression) != nil
    }

    private static func duplicates(_ values: [String]) -> Set<String> {
        var seen: Set<String> = []
        var duplicate: Set<String> = []
        for value in values where !seen.insert(value).inserted {
            duplicate.insert(value)
        }
        return duplicate
    }
}

public extension AdapterID {
    /// Deterministically converts an implementation/plugin identifier into
    /// Mary's portable adapter namespace. This keeps package bindings stable
    /// across machines even when a local type uses underscores or spaces.
    static func normalized(_ value: String) -> AdapterID {
        var result = ""
        var previousWasSeparator = false
        for character in value.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
                previousWasSeparator = false
            } else if (character == "." || character == "-"),
                      !previousWasSeparator,
                      !result.isEmpty {
                result.append(character)
                previousWasSeparator = true
            } else if !previousWasSeparator && !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if result.first?.isLetter != true {
            result = result.isEmpty ? "adapter-unknown" : "adapter-\(result)"
        }
        return AdapterID(result)
    }
}

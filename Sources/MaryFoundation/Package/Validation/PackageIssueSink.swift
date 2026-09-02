//
//  PackageIssueSink.swift
//  MaryFoundation
//
//  WHAT: Shared vocabulary checks + issue collector for package admission.
//  IN:   AbilityPackageValidator siblings.
//  OUT:  SchemaIssue list.
//

import Foundation

final class PackageIssueSink {
    var issues: [SchemaIssue] = []

    func error(_ code: String, _ path: String, _ message: String) {
        issues.append(.init(severity: .error, code: code, path: path, message: message))
    }

    func warning(_ code: String, _ path: String, _ message: String) {
        issues.append(.init(severity: .warning, code: code, path: path, message: message))
    }

    func checkID(_ value: String, _ path: String) {
        if !SchemaIdentifierValidation.isValid(value) {
            error("invalid-id", path, "Use a lower-case portable identifier containing letters, numbers, dots, or hyphens.")
        }
    }

    func checkText(_ value: String, _ path: String, _ noun: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("missing-\(noun)", path, "Every \(noun.replacingOccurrences(of: "-", with: " ")) must contain text.")
        }
    }

    /// Bounded canonical search terms so empty/punctuation cannot match every utterance.
    func validateSearchTerms(
        _ values: [String],
        path: String,
        noun: String,
        maximumWordsPerTerm: Int = 12
    ) {
        let maximumTerms = 64
        let maximumTermBytes = 128
        if values.count > maximumTerms {
            error(
                "too-many-routing-terms",
                path,
                "A \(noun) list may contain at most \(maximumTerms) terms.")
        }
        let inspected = Array(values.prefix(maximumTerms))
        AbilityPackageValidator.duplicates(inspected).forEach { _ in
            error(
                "duplicate-routing-term",
                path,
                "A routing term appears more than once.")
        }
        for (index, value) in inspected.enumerated() {
            let words = value.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            let canonical = words.joined(separator: " ")
            if words.isEmpty
                || words.count > maximumWordsPerTerm
                || value.utf8.count > maximumTermBytes
                || value != canonical {
                error(
                    "invalid-routing-term",
                    "\(path)[\(index)]",
                    "Routing terms use one to \(maximumWordsPerTerm) lower-case words separated by single spaces and at most \(maximumTermBytes) UTF-8 bytes.")
            }
        }
    }

    func validatePredicate(_ predicate: RoutingPredicate, path: String) {
        switch predicate.kind {
        case .all, .any:
            if predicate.children.isEmpty {
                error("empty-routing-group", path, "A routing \(predicate.kind.rawValue) predicate needs at least one child.")
            }
            if predicate.value != nil {
                error("routing-group-value", "\(path).value", "Routing groups cannot carry a scalar value.")
            }
        case .not:
            if predicate.children.count != 1 {
                error("invalid-routing-not", path, "A routing not predicate needs exactly one child.")
            }
            if predicate.value != nil {
                error("routing-group-value", "\(path).value", "A routing not predicate cannot carry a scalar value.")
            }
        default:
            if predicate.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                error("missing-routing-value", "\(path).value", "A leaf routing predicate needs a value.")
            }
            if !predicate.children.isEmpty {
                error("routing-leaf-children", "\(path).children", "A leaf routing predicate cannot have children.")
            }
        }
        if let value = predicate.value {
            switch predicate.kind {
            case .hasInteraction, .hasPerception, .hasCapability:
                checkID(value, "\(path).value")
            case .permissionGranted:
                if PermissionKind(rawValue: value) == nil {
                    error("unknown-permission", "\(path).value", "The router names an unknown permission kind.")
                }
            case .sourceResolution:
                if SourceResolution(rawValue: value) == nil {
                    error("unknown-source-resolution", "\(path).value", "The router names an unknown source resolution.")
                }
            case .utteranceToken, .utterancePhrase:
                // A WARNING, NOT AN ERROR — the kinds stay decodable so a
                // sealed third-party package still loads and still routes.
                warning(
                    "utterance-literal-in-routing", "\(path).value",
                    """
                    "\(value)" matches the user's words inside a routing predicate. \
                    Author it under ability.triggers instead: utterances are matched \
                    semantically against the trigger corpus, and a literal here is a \
                    SECOND matcher over the same authoring surface — one that only \
                    runs when the machine has no embedding model, and that silently \
                    disagrees with the corpus when it does.
                    """)
            default: break
            }
        }
        for (index, child) in predicate.children.enumerated() {
            validatePredicate(child, path: "\(path).children[\(index)]")
        }
    }

    func validateRouting(_ routing: RoutingPolicySchema, path: String) {
        if let predicate = routing.eligibility {
            validatePredicate(predicate, path: "\(path).eligibility")
        }
        for (index, predicate) in routing.excludes.enumerated() {
            validatePredicate(predicate, path: "\(path).excludes[\(index)]")
        }
        if let group = routing.conflictGroup,
           !group.isEmpty,
           !SchemaIdentifierValidation.isValid(group) {
            error("invalid-conflict-group", "\(path).conflictGroup", "Conflict groups use portable lower-case identifiers.")
        }
    }
}

extension AbilityPackageValidator {
    static func isHexTint(_ value: String) -> Bool {
        guard value.count == 7, value.first == "#" else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    static func semanticVersionIsValid(_ value: String) -> Bool {
        SemanticVersion.isValid(value)
    }

    static func callableNameIsValid(_ value: String) -> Bool {
        value.utf8.count <= SchemaIdentifierValidation.maximumUTF8Length
            && value.range(
                of: #"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$"#,
                options: .regularExpression) != nil
    }

    /// Short opaque enum cases — no instruction prose through a typed field.
    static func machineTokenIsValid(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#,
            options: .regularExpression) != nil
    }

    static func duplicates(_ values: [String]) -> Set<String> {
        var seen: Set<String> = []
        var duplicate: Set<String> = []
        for value in values where !seen.insert(value).inserted { duplicate.insert(value) }
        return duplicate
    }

    static func validateUnique(
        _ values: [(String, String)],
        code: String,
        issues: inout [SchemaIssue]
    ) {
        for duplicate in duplicates(values.map(\.0)) {
            issues.append(.init(
                severity: .error,
                code: code,
                path: values.first(where: { $0.0 == duplicate })?.1 ?? "schemas",
                message: "Schema id \(duplicate) appears more than once."))
        }
    }
}

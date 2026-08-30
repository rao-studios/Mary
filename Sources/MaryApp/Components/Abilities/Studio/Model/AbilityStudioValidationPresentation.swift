import MaryBrain
import Foundation

/// UI-facing package-graph validation. Unavailable Plugin is a warning, not an authoring failure.
struct AbilityStudioValidationPresentation: Hashable {
    let errors: [SchemaIssue]
    let actionableWarnings: [SchemaIssue]
    let coverageGroups: [AbilityStudioProviderCoverageGroup]

    var isValid: Bool { errors.isEmpty }

    init(validation: AbilityPackageValidation) {
        var errors: [SchemaIssue] = []
        var actionableWarnings: [SchemaIssue] = []
        var coverageByPackage: [PackageID: [SchemaIssue]] = [:]

        for issue in validation.issues {
            if issue.severity == .error {
                errors.append(issue)
            } else if issue.code == Self.providerUnavailableCode,
                      let packageID = Self.owningPackageID(for: issue.path) {
                coverageByPackage[packageID, default: []].append(issue)
            } else {
                // Never hide an unknown or malformed warning merely because it
                // happens to reuse the provider-unavailable code.
                actionableWarnings.append(issue)
            }
        }

        self.errors = errors.sorted(by: Self.issueOrder)
        self.actionableWarnings = actionableWarnings.sorted(by: Self.issueOrder)
        coverageGroups = coverageByPackage.map { packageID, issues in
            AbilityStudioProviderCoverageGroup(
                packageID: packageID,
                issues: issues.sorted(by: Self.issueOrder))
        }.sorted {
            $0.packageID.rawValue < $1.packageID.rawValue
        }
    }

    private static let providerUnavailableCode = "dynamic-provider-unavailable"
    private static let skillsPathMarker = ".skills."
    private static let bindingPathSuffix = ".execution.bindings"

    private static func owningPackageID(for path: String) -> PackageID? {
        guard let marker = path.range(of: skillsPathMarker),
              marker.lowerBound != path.startIndex,
              path.hasSuffix(bindingPathSuffix)
        else { return nil }
        let skillStart = marker.upperBound
        let skillEnd = path.index(path.endIndex, offsetBy: -bindingPathSuffix.count)
        guard skillStart < skillEnd else { return nil }
        return PackageID(String(path[..<marker.lowerBound]))
    }

    private static func issueOrder(_ left: SchemaIssue, _ right: SchemaIssue) -> Bool {
        if left.path != right.path { return left.path < right.path }
        if left.code != right.code { return left.code < right.code }
        return left.message < right.message
    }
}

struct AbilityStudioProviderCoverageGroup: Hashable, Identifiable {
    let packageID: PackageID
    let issues: [SchemaIssue]

    var id: PackageID { packageID }
    var unavailableSkillCount: Int { issues.count }

    /// Skill identities are recovered only for concise Studio labels. The
    /// original schema issues remain available for complete diagnostics.
    var skillIDs: [SkillID] {
        issues.compactMap { issue in
            let prefix = "\(packageID.rawValue).skills."
            let suffix = ".execution.bindings"
            guard issue.path.hasPrefix(prefix), issue.path.hasSuffix(suffix) else {
                return nil
            }
            let start = issue.path.index(issue.path.startIndex, offsetBy: prefix.count)
            let end = issue.path.index(issue.path.endIndex, offsetBy: -suffix.count)
            guard start < end else { return nil }
            return SkillID(String(issue.path[start..<end]))
        }
    }
}

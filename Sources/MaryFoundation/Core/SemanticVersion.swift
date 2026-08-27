import Foundation

/// Semantic version encoded as a JSON string. Comparison follows SemVer 2.0
/// precedence without converting numeric identifiers to fixed-width integers,
/// so even the largest package-authored version cannot overflow a gate.
public struct SemanticVersion: Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = Parsed(lhs.rawValue),
              let right = Parsed(rhs.rawValue)
        else {
            // Invalid package versions are rejected by graph validation. This
            // fallback only supplies deterministic ordering to callers that
            // construct a SemanticVersion directly.
            return lhs.rawValue < rhs.rawValue
        }

        for index in 0..<3 {
            let comparison = compareNumeric(left.core[index], right.core[index])
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (leftIdentifiers?, rightIdentifiers?):
            for index in 0..<min(leftIdentifiers.count, rightIdentifiers.count) {
                let leftIdentifier = leftIdentifiers[index]
                let rightIdentifier = rightIdentifiers[index]
                if leftIdentifier == rightIdentifier { continue }
                let leftIsNumeric = Self.isNumeric(leftIdentifier)
                let rightIsNumeric = Self.isNumeric(rightIdentifier)
                switch (leftIsNumeric, rightIsNumeric) {
                case (true, true):
                    return compareNumeric(leftIdentifier, rightIdentifier)
                        == .orderedAscending
                case (true, false): return true
                case (false, true): return false
                case (false, false): return leftIdentifier < rightIdentifier
                }
            }
            return leftIdentifiers.count < rightIdentifiers.count
        }
    }

    public static func isValid(_ value: String) -> Bool {
        Parsed(value) != nil
    }

    private struct Parsed {
        var core: [String]
        var prerelease: [String]?

        init?(_ value: String) {
            guard !value.isEmpty,
                  value.utf8.count <= SchemaIdentifierValidation.maximumUTF8Length,
                  value.filter({ $0 == "+" }).count <= 1
            else { return nil }

            let buildSplit = value.split(
                separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            guard !buildSplit[0].isEmpty else { return nil }
            if buildSplit.count == 2 {
                guard Self.identifiersAreValid(
                    String(buildSplit[1]), rejectNumericLeadingZeros: false)
                else { return nil }
            }

            let precedence = buildSplit[0].split(
                separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = precedence[0].split(
                separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard core.count == 3,
                  core.allSatisfy(Self.isCoreIdentifier)
            else { return nil }

            let prerelease: [String]?
            if precedence.count == 2 {
                let text = String(precedence[1])
                guard Self.identifiersAreValid(
                    text, rejectNumericLeadingZeros: true)
                else { return nil }
                prerelease = text.split(
                    separator: ".", omittingEmptySubsequences: false).map(String.init)
            } else {
                prerelease = nil
            }
            self.core = core
            self.prerelease = prerelease
        }

        private static func isCoreIdentifier(_ value: String) -> Bool {
            SemanticVersion.isNumeric(value)
                && (value == "0" || value.first != "0")
        }

        private static func identifiersAreValid(
            _ value: String,
            rejectNumericLeadingZeros: Bool
        ) -> Bool {
            let identifiers = value.split(
                separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty else { return false }
            return identifiers.allSatisfy { identifier in
                guard !identifier.isEmpty,
                      identifier.utf8.allSatisfy({ byte in
                          (48...57).contains(byte)
                              || (65...90).contains(byte)
                              || (97...122).contains(byte)
                              || byte == 45
                      })
                else { return false }
                return !rejectNumericLeadingZeros
                    || !SemanticVersion.isNumeric(identifier)
                    || identifier == "0"
                    || identifier.first != "0"
            }
        }
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func compareNumeric(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        let left = lhs.drop(while: { $0 == "0" })
        let right = rhs.drop(while: { $0 == "0" })
        let normalizedLeft = left.isEmpty ? "0" : String(left)
        let normalizedRight = right.isEmpty ? "0" : String(right)
        if normalizedLeft.count != normalizedRight.count {
            return normalizedLeft.count < normalizedRight.count
                ? .orderedAscending : .orderedDescending
        }
        if normalizedLeft == normalizedRight { return .orderedSame }
        return normalizedLeft < normalizedRight
            ? .orderedAscending : .orderedDescending
    }
}

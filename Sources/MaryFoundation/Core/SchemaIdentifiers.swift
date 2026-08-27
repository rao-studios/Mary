import Foundation

/// A stable, portable identifier used by Mary's schema graph.
///
/// Identifiers are lower-case, dot-separated names such as `writing` or
/// `interaction.text-selection`. They never contain a machine-local path,
/// plugin instance, process id, or display name.
public protocol SchemaIdentifier: RawRepresentable, Codable, Hashable,
    Sendable, CustomStringConvertible, ExpressibleByStringLiteral
where RawValue == String {
    init(_ rawValue: String)
}

public extension SchemaIdentifier {
    init(stringLiteral value: String) { self.init(value) }
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AbilityID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }

    public static let writing: Self = "writing"
    public static let architect: Self = "architect"
    public static let coding: Self = "coding"
    public static let windowManagement: Self = "window-management"
    public static let design: Self = "design"
    /// Named in Swift because the ambient layer asks "does this registration
    /// realize browsing?" to decide whether a bundle is a browser at all —
    /// which is how Chrome and any later browser package join the browser
    /// workspace without being written into a compiled table.
    public static let browsing: Self = "browsing"
    // NO ENTRY IS REQUIRED HERE TO SHIP A `.mary`. `AbilityID` is
    // `ExpressibleByStringLiteral`, so `"shaderfeel"` is a complete identifier
    // wherever one is wanted; these six exist only because compiled Swift
    // refers to them by name often enough that a typo should be a build error.
    // A package nothing in Swift names by hand — ShaderFeel is the first — adds
    // nothing here, and the prompt registry derives its label from the id
    // rather than from a case (see `AbilityPromptProjection.contractLabel`).
}

public struct SkillID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
}

public struct CapabilityID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
}

public struct ArtifactDomainID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
}

public struct InteractionID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }

    public static let textSelection: Self = "interaction.text-selection"
    public static let codeSelection: Self = "interaction.code-selection"
    public static let projectReference: Self = "interaction.project-reference"
    public static let windowReference: Self = "interaction.window-reference"
}

public struct PerceptionID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }

    public static let workspaceFocus: Self = "perception.workspace-focus"
    public static let viewport: Self = "perception.viewport"
    public static let hover: Self = "perception.hover"
    public static let codeWorkspaceFocus: Self = "perception.code-workspace-focus"
    public static let buildState: Self = "perception.build-state"
    public static let projectFocus: Self = "perception.project-focus"
    public static let textSurfaceFocus: Self = "perception.text-surface-focus"
    public static let applicationFocus: Self = "perception.application-focus"
    public static let windowFocus: Self = "perception.window-focus"
}

public struct ValueTypeID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
}

public struct ProjectionID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
}

public struct AdapterID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
}

public struct PackageID: SchemaIdentifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.init(rawValue) }
}

public enum SchemaIdentifierValidation {
    public static let maximumUTF8Length = 128

    /// Portable ids intentionally use a smaller alphabet than Swift symbols,
    /// file names, or provider tool names.
    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Length,
              value.first?.isLetter == true,
              value == value.lowercased(),
              !value.contains(".."),
              !value.hasSuffix("."),
              !value.hasSuffix("-")
        else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." || $0 == "-" }
    }
}

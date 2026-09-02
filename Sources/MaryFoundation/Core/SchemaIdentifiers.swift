//
//  SchemaIdentifiers.swift
//  MaryFoundation
//
//  WHAT: Portable dotted ids for the schema graph (abilities, skills, perceptions).
//  IN:   `.mary` decode / AbilityPackageValidator → these wrappers.
//  OUT:  SkillSchemas, InstalledAdapterInventory, AbilityRuntime.
//  PIN:  No machine-local path, plugin instance, pid, or display name.
//

import Foundation

/// Lower-case dotted id (`writing`, `interaction.text-selection`).
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
    /// The craft of already knowing what the work in front of you is: the unit
    /// under the cursor, what reaches it, what it reaches. Named so a place can
    /// ask "does this registration realize awareness?" without naming an app.
    public static let awareness: Self = "awareness"
    public static let windowManagement: Self = "window-management"
    public static let design: Self = "design"
    /// Named so ambient can ask "does this registration realize browsing?"
    /// OUT: browser workspace membership without a compiled table.
    public static let browsing: Self = "browsing"
    // PIN: Packages ship ids as string literals. These cases are Swift call-sites
    //      only (`AbilityPromptProjection.contractLabel` derives labels from the id).
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

/// Perceptions AbilityRuntime concludes from an adapter-claimed one.
/// OUT: InstalledAdapterInventory (static claims) + AbilityRuntime (turn insert).
/// PIN: Rows = insertion sites. `text-surface-focus` stays off — optional, nothing derives it.
public enum DerivedPerceptions {

    public static let base: [PerceptionID: PerceptionID] = [
        .codeWorkspaceFocus: .workspaceFocus,
        .projectFocus: .workspaceFocus,
    ]
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

    /// Smaller alphabet than Swift symbols or provider tool names.
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

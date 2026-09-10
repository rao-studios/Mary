//
//  PluginApplicationSchema.swift
//  MaryFoundation
//
//  WHAT: Application identity, activation, window measure, perception, release.
//  IN:   PluginSchema.application.
//  OUT:  PluginValidator+Validate, ambient observation.
//

import Foundation

/// Trusted interpreter. New engines need a Mary runtime release.
public enum PluginEngine: String, Codable, Hashable, Sendable, CaseIterable {
    case macUI
}

/// Recipes never launch software. Frontmost or already-running only.
public enum PluginApplicationActivation: String, Codable, Hashable, Sendable, CaseIterable {
    case requireFrontmost
    case activateRunning
}

public struct PluginWindowInsets: Codable, Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(
        top: Double = 0,
        leading: Double = 0,
        bottom: Double = 0,
        trailing: Double = 0
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case top
        case leading
        case bottom
        case trailing
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        top = try values.decode(Double.self, forKey: .top)
        leading = try values.decode(Double.self, forKey: .leading)
        bottom = try values.decode(Double.self, forKey: .bottom)
        trailing = try values.decode(Double.self, forKey: .trailing)
    }
}

/// Process identity + window geometry. Optional perception opt-in to Mary's AX observer.
public struct PluginApplicationPerceptionSchema: Codable, Hashable, Sendable {

    /// Which Mary-owned observer to point here. Package supplies neither reader nor cadence.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// Live selection via generic Accessibility reader. No package timer or script.
        case perceptionOnly
        /// Selection plus Mary's corpus reader. Validator requires a corpus declaration.
        case workspace
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        // Legacy polling is executable policy — fail closed.
        case documentOperation
        case pollSeconds
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.documentOperation) || container.contains(.pollSeconds) {
            let key: CodingKeys = container.contains(.documentOperation)
                ? .documentOperation : .pollSeconds
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Plugin perception is Mary-owned; package document operations and polling cadences are not supported.")
        }
        kind = try container.decode(Kind.self, forKey: .kind)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
    }
}

/// Exact release tuple for UI-profile conformance. Compare bytes; never authorize execution.
public struct PluginApplicationReleaseSchema: Codable, Hashable, Sendable {
    public var shortVersion: String
    public var bundleVersion: String

    public init(shortVersion: String, bundleVersion: String) {
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case shortVersion
        case bundleVersion
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortVersion = try container.decode(String.self, forKey: .shortVersion)
        bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
    }
}

public struct PluginApplicationSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var aliases: [String]
    public var bundleIdentifiers: [String]
    /// Family prefix for membership (scrivener3/4). Launch still uses exact bundleIdentifiers.
    public var bundleIdentifierPrefix: String?
    /// Path-free application bundle names used as human routing aliases. Bundle
    /// identifiers remain the authority used to select a running process.
    public var bundleNames: [String]
    /// Exact releases for which this package's UI profile was conformed.
    /// Empty preserves the legacy unconstrained behavior and canonical bytes.
    public var supportedReleases: [PluginApplicationReleaseSchema]
    public var targetClasses: [String]
    public var activation: PluginApplicationActivation
    /// Insets remove fixed application chrome from normalized pointer recipes.
    /// They are points inside the frontmost standard window, not screen pixels.
    public var contentInsets: PluginWindowInsets
    /// Optional watch. Nil = operate only, not observe.
    public var perception: PluginApplicationPerceptionSchema?

    public init(
        id: String,
        title: String,
        aliases: [String] = [],
        bundleIdentifiers: [String],
        bundleIdentifierPrefix: String? = nil,
        bundleNames: [String] = [],
        supportedReleases: [PluginApplicationReleaseSchema] = [],
        targetClasses: [String] = [],
        activation: PluginApplicationActivation = .activateRunning,
        contentInsets: PluginWindowInsets = .init(),
        perception: PluginApplicationPerceptionSchema? = nil
    ) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.bundleIdentifiers = bundleIdentifiers
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
        self.bundleNames = bundleNames
        self.supportedReleases = supportedReleases
        self.targetClasses = targetClasses
        self.activation = activation
        self.contentInsets = contentInsets
        self.perception = perception
    }

    /// Family membership (narrower than hasPrefix). Not launch authority.
    public static func bundleIdentifier(
        _ bundleIdentifier: String,
        isInFamily prefix: String
    ) -> Bool {
        let identifier = bundleIdentifier.lowercased()
        let family = prefix.lowercased()
        guard !family.isEmpty, identifier.hasPrefix(family) else { return false }
        var remainder = Substring(identifier.dropFirst(family.count))
        if remainder.isEmpty { return true }
        while let first = remainder.first, first.isNumber {
            remainder = remainder.dropFirst()
        }
        return remainder.isEmpty || remainder.first == "."
    }

    /// Overlapping families: some exact id could satisfy both. Admission must not use roster order.
    public static func familyPrefix(
        _ lhs: String,
        overlaps rhs: String
    ) -> Bool {
        bundleIdentifier(lhs, isInFamily: rhs)
            || bundleIdentifier(rhs, isInFamily: lhs)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case title
        case aliases
        case bundleIdentifiers
        case bundleIdentifierPrefix
        case bundleNames
        case supportedReleases
        case targetClasses
        case activation
        case contentInsets
        case perception
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        aliases = try container.decode([String].self, forKey: .aliases)
        bundleIdentifiers = try container.decode([String].self, forKey: .bundleIdentifiers)
        bundleIdentifierPrefix = try container.decodeIfPresent(
            String.self, forKey: .bundleIdentifierPrefix)
        bundleNames = try container.decodeIfPresent([String].self, forKey: .bundleNames) ?? []
        supportedReleases = try container.decodeIfPresent(
            [PluginApplicationReleaseSchema].self,
            forKey: .supportedReleases) ?? []
        targetClasses = try container.decode([String].self, forKey: .targetClasses)
        activation = try container.decode(PluginApplicationActivation.self, forKey: .activation)
        contentInsets = try container.decode(PluginWindowInsets.self, forKey: .contentInsets)
        perception = try container.decodeIfPresent(
            PluginApplicationPerceptionSchema.self, forKey: .perception)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(bundleIdentifiers, forKey: .bundleIdentifiers)
        if let bundleIdentifierPrefix {
            try container.encode(bundleIdentifierPrefix, forKey: .bundleIdentifierPrefix)
        }
        // Omit empty bundleNames — preserve original canonical bytes.
        if !bundleNames.isEmpty {
            try container.encode(bundleNames, forKey: .bundleNames)
        }
        // Empty supportedReleases omitted — original bytes.
        if !supportedReleases.isEmpty {
            try container.encode(supportedReleases, forKey: .supportedReleases)
        }
        try container.encode(targetClasses, forKey: .targetClasses)
        try container.encode(activation, forKey: .activation)
        try container.encode(contentInsets, forKey: .contentInsets)
        // Omit absent perception — pre-perception packages keep their digest.
        if let perception {
            try container.encode(perception, forKey: .perception)
        }
    }
}

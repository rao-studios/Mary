//
//  PluginApplicationSchema.swift
//  MaryFoundation
//
//  THE APPLICATION A PLUGIN DRIVES: how it is identified and
//  activated, how its window is measured, what perception of it the plugin
//  may take, and how the plugin lets go of it.
//

import Foundation

/// The trusted interpreter used by a Plugin. New engines require a
/// Mary runtime release; packages cannot name arbitrary executables.
public enum PluginEngine: String, Codable, Hashable, Sendable, CaseIterable {
    case macUI
}

/// Plugin recipes never launch software. They either require the
/// user-owned application to be frontmost or activate an already-running
/// process before acting.
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

/// Exact process identity and visible-window geometry for one taught app.
/// HOW A PLUGIN APPLICATION CAN BE OBSERVED — the declaration that upgrades a
/// recognized application to a watched one.
///
/// A data-only opt-in to Mary's generic Accessibility perception. Packages
/// cannot supply a reader, polling cadence, or executable document operation;
/// observation remains wholly Mary-owned.
public struct PluginApplicationPerceptionSchema: Codable, Hashable, Sendable {

    /// Closed to the native observation classes Plugins can claim.
    ///
    /// Both are opt-ins to machinery Mary already owns. Neither lets a
    /// package supply the reader, the cadence, or the operation — the claim
    /// only says WHICH of Mary's observers should be pointed at this
    /// application.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// Live selection only, through the generic Accessibility reader. No
        /// package operation, timer, or script participates.
        case perceptionOnly
        /// Selection PLUS a document channel — and the channel is Mary's own
        /// corpus reader, never a package operation.
        ///
        /// VALID ONLY ALONGSIDE A DECLARED `documentCorpus`, enforced by the
        /// validator. Eyes have always been two halves — a workspace class and
        /// a real way to be observed — and a package that could claim the
        /// first half alone would render a card claiming live knowledge of a
        /// document nothing is reading. The corpus declaration IS the second
        /// half, which is why the two are checked together rather than trusted
        /// separately.
        case workspace
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        // Legacy polling configuration is executable policy and must fail
        // closed rather than being silently ignored.
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

/// One exact application release tuple conformed by a package-owned UI
/// profile. Neither field is a range: presentation compares both strings
/// byte-for-byte to show whether the observed build was verified, never to
/// authorize execution.
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
    /// THE FAMILY, when an application's identifier carries its major version.
    ///
    /// `bundleIdentifiers` is exact and stays the authority for LAUNCHING and
    /// for choosing a process. But membership — "is the app in front one of
    /// this package's?" — is a prefix question for any vendor who ships
    /// `…scrivener3` and then `…scrivener4`, or a Setapp build alongside a
    /// direct one. Without it a next-major release reads as a different
    /// application: pinned and focus-tracked, yet simultaneously reported "not
    /// running". Absent means the exact identifiers are the whole answer.
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
    /// HOW THIS APPLICATION MAY BE OBSERVED, when the package wants Mary to
    /// watch it rather than only operate it.
    ///
    /// Nil is the default and the honest one: teaching Mary to drive an
    /// application has not taught her to see it, and a package that claimed
    /// sight it could not supply would produce a live-looking card over a
    /// document nothing reads.
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

    /// Whether `bundleIdentifier` belongs to the declared process family.
    ///
    /// Family identity is deliberately narrower than `hasPrefix`: an empty
    /// suffix, a major-version digit run, or a new dot component is admitted;
    /// a letter immediately after the prefix is a different product. Keeping
    /// this rule in the schema gives admission and runtime projection one
    /// canonical boundary predicate without turning a family into launch or
    /// exact-process authority.
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

    /// Two family declarations overlap when either family root is itself a
    /// member of the other. In that case some exact bundle identifier could
    /// satisfy both ownership claims, so package admission must not rely on
    /// roster order to decide which application owns it.
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
        // `bundleNames` was added after Plugin packages shipped. Omitting an
        // empty value preserves the canonical bytes (and therefore existing
        // digests/signatures) of packages decoded from the original schema.
        if !bundleNames.isEmpty {
            try container.encode(bundleNames, forKey: .bundleNames)
        }
        // Release conformance was added after Plugin packages shipped. An
        // empty list remains byte-identical to the original schema.
        if !supportedReleases.isEmpty {
            try container.encode(supportedReleases, forKey: .supportedReleases)
        }
        try container.encode(targetClasses, forKey: .targetClasses)
        try container.encode(activation, forKey: .activation)
        try container.encode(contentInsets, forKey: .contentInsets)
        // Same reasoning as `bundleNames` above: omitted when absent, so every
        // package that shipped before perception existed keeps its canonical
        // bytes and therefore its digest.
        if let perception {
            try container.encode(perception, forKey: .perception)
        }
    }
}

import Foundation

public struct AbilityPackageMetadata: Codable, Hashable, Sendable {
    public var id: PackageID
    public var version: SemanticVersion
    public var publisher: String
    /// Inspector and catalog metadata. It never becomes model instruction
    /// text, whether the package is bundled, signed, or unsigned.
    public var summary: String
    public var minimumMaryVersion: SemanticVersion?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: PackageID,
        version: SemanticVersion,
        publisher: String,
        summary: String,
        minimumMaryVersion: SemanticVersion? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.version = version
        self.publisher = publisher
        self.summary = summary
        self.minimumMaryVersion = minimumMaryVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AbilityPackageDependency: Codable, Hashable, Sendable {
    public var packageID: PackageID
    public var minimumVersion: SemanticVersion
    public var optional: Bool

    public init(packageID: PackageID, minimumVersion: SemanticVersion, optional: Bool = false) {
        self.packageID = packageID
        self.minimumVersion = minimumVersion
        self.optional = optional
    }
}

public struct AbilityPackageIntegrity: Codable, Hashable, Sendable {
    public var algorithm: String
    public var digest: String
    public var signatureAlgorithm: String?
    public var publicKey: String?
    public var signature: String?

    public init(
        algorithm: String = "sha256",
        digest: String,
        signatureAlgorithm: String? = nil,
        publicKey: String? = nil,
        signature: String? = nil
    ) {
        self.algorithm = algorithm
        self.digest = digest
        self.signatureAlgorithm = signatureAlgorithm
        self.publicKey = publicKey
        self.signature = signature
    }

    public var isSigned: Bool { publicKey != nil && signature != nil }
}

/// The complete single-file `.mary` envelope. JSON is the portable source
/// of truth. Native executable implementations remain local to the receiving
/// machine; an optional Plugin contributes only bounded declarative
/// recipes interpreted by Mary's trusted runtime.
public struct MaryAbilityPackage: Codable, Hashable, Sendable {
    public static let format = "mary.ability-package"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var package: AbilityPackageMetadata
    public var ability: AbilitySchema
    public var skills: [SkillSchema]
    public var capabilities: [CapabilitySchema]
    public var interactions: [InteractionSchema]
    public var perceptions: [PerceptionSchema]
    public var valueTypes: [ValueTypeSchema]
    public var totemProjections: [TotemProjectionSchema]
    public var dependencies: [AbilityPackageDependency]
    public var fixtures: [AbilityFixture]
    public var plugin: PluginSchema?
    /// Craft grammar a discipline can declare without carrying an application
    /// Plugin. Expertise packages bind this to a live app, or override it with
    /// `plugin.corpus`.
    public var corpus: PluginCorpusSchema?
    public var integrity: AbilityPackageIntegrity?

    public init(
        package: AbilityPackageMetadata,
        ability: AbilitySchema,
        skills: [SkillSchema],
        capabilities: [CapabilitySchema] = [],
        interactions: [InteractionSchema] = [],
        perceptions: [PerceptionSchema] = [],
        valueTypes: [ValueTypeSchema] = [],
        totemProjections: [TotemProjectionSchema] = [],
        dependencies: [AbilityPackageDependency] = [],
        fixtures: [AbilityFixture] = [],
        plugin: PluginSchema? = nil,
        corpus: PluginCorpusSchema? = nil,
        integrity: AbilityPackageIntegrity? = nil
    ) {
        self.format = Self.format
        self.formatVersion = Self.currentFormatVersion
        self.package = package
        self.ability = ability
        self.skills = skills
        self.capabilities = capabilities
        self.interactions = interactions
        self.perceptions = perceptions
        self.valueTypes = valueTypes
        self.totemProjections = totemProjections
        self.dependencies = dependencies
        self.fixtures = fixtures
        self.plugin = plugin
        self.corpus = corpus
        self.integrity = integrity
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format
        case formatVersion
        case package
        case ability
        case skills
        case capabilities
        case interactions
        case perceptions
        case valueTypes
        case totemProjections
        case dependencies
        case fixtures
        case plugin
        case corpus
        case integrity
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        package = try values.decode(AbilityPackageMetadata.self, forKey: .package)
        ability = try values.decode(AbilitySchema.self, forKey: .ability)
        skills = try values.decode([SkillSchema].self, forKey: .skills)
        capabilities = try values.decode([CapabilitySchema].self, forKey: .capabilities)
        interactions = try values.decode([InteractionSchema].self, forKey: .interactions)
        perceptions = try values.decode([PerceptionSchema].self, forKey: .perceptions)
        valueTypes = try values.decode([ValueTypeSchema].self, forKey: .valueTypes)
        totemProjections = try values.decode(
            [TotemProjectionSchema].self, forKey: .totemProjections)
        dependencies = try values.decode(
            [AbilityPackageDependency].self, forKey: .dependencies)
        fixtures = try values.decode([AbilityFixture].self, forKey: .fixtures)
        plugin = try values.decodeIfPresent(
            PluginSchema.self, forKey: .plugin)
        corpus = try values.decodeIfPresent(
            PluginCorpusSchema.self, forKey: .corpus)
        integrity = try values.decodeIfPresent(
            AbilityPackageIntegrity.self, forKey: .integrity)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(format, forKey: .format)
        try values.encode(formatVersion, forKey: .formatVersion)
        try values.encode(package, forKey: .package)
        try values.encode(ability, forKey: .ability)
        try values.encode(skills, forKey: .skills)
        try values.encode(capabilities, forKey: .capabilities)
        try values.encode(interactions, forKey: .interactions)
        try values.encode(perceptions, forKey: .perceptions)
        try values.encode(valueTypes, forKey: .valueTypes)
        try values.encode(totemProjections, forKey: .totemProjections)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(fixtures, forKey: .fixtures)
        try values.encodeIfPresent(plugin, forKey: .plugin)
        try values.encodeIfPresent(corpus, forKey: .corpus)
        try values.encodeIfPresent(integrity, forKey: .integrity)
    }
}

public struct AbilityFixture: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var utterance: String
    public var expectedSkill: SkillID?
    public var interactions: [InteractionID]
    public var targetClass: String?
    public var expectedDisposition: String

    public init(
        id: String,
        utterance: String,
        expectedSkill: SkillID? = nil,
        interactions: [InteractionID] = [],
        targetClass: String? = nil,
        expectedDisposition: String
    ) {
        self.id = id
        self.utterance = utterance
        self.expectedSkill = expectedSkill
        self.interactions = interactions
        self.targetClass = targetClass
        self.expectedDisposition = expectedDisposition
    }
}


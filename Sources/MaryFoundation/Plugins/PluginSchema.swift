//
//  PluginSchema.swift
//  MaryFoundation
//
//  WHAT: Whole Plugin — application, adapters, operations, realizations, surfaces.
//  IN:   MaryAbilityPackage.plugin → PluginValidator.
//  OUT:  +CodeSurface / +ProseSurface / +Media / +Corpus siblings.
//  PIN:  Data only. Operations cannot return values; recipes are fixed step arrays.
//

import Foundation

/// Ability Skill → Plugin operation. Application teaches a discipline without the discipline naming it.
public struct PluginSkillRealizationSchema: Codable, Hashable, Sendable {
    public var skillID: SkillID
    public var operation: String
    public var preference: Int
    public var targetClasses: [String]

    public init(
        skillID: SkillID,
        operation: String,
        preference: Int = 100,
        targetClasses: [String] = []
    ) {
        self.skillID = skillID
        self.operation = operation
        self.preference = preference
        self.targetClasses = targetClasses
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case skillID
        case operation
        case preference
        case targetClasses
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        skillID = try values.decode(SkillID.self, forKey: .skillID)
        operation = try values.decode(String.self, forKey: .operation)
        preference = try values.decode(Int.self, forKey: .preference)
        targetClasses = try values.decode([String].self, forKey: .targetClasses)
    }
}

/// A declarative Plugin payload carried by an Ability package.
public struct PluginSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var version: SemanticVersion
    public var title: String
    public var application: PluginApplicationSchema
    public var adapters: [PluginAdapterSchema]
    public var operations: [PluginOperationSchema]
    public var realizations: [PluginSkillRealizationSchema]

    /// Prose-surface coordinates for Mary's generic reader/writer. Not a recipe.
    public var proseSurface: PluginProseSurfaceSchema?

    /// Code-buffer coordinates. Read-only sibling of proseSurface. See PluginCodeSurfaceSchema.
    public var codeSurface: PluginCodeSurfaceSchema?

    /// Transport coordinates. See PluginMediaSurfaceSchema.
    public var mediaSurface: PluginMediaSurfaceSchema?

    /// Project-on-disk shape. Evidence half of workspace eyes. See PluginCorpusSchema.
    public var corpus: PluginCorpusSchema?

    /// The single-adapter view. Valid Plugins always declare at least one.
    public var adapter: PluginAdapterSchema {
        get { adapters[0] }
        set { adapters[0] = newValue }
    }

    /// Resolves an operation's interpreter: its explicit `adapterID`, else the
    /// Plugin's sole adapter. Nil when the reference names no declared adapter.
    public func adapter(for operation: PluginOperationSchema) -> PluginAdapterSchema? {
        guard let adapterID = operation.adapterID else {
            return adapters.count == 1 ? adapters.first : nil
        }
        return adapters.first { $0.id == adapterID }
    }

    public init(
        id: String,
        version: SemanticVersion = "1.0.0",
        title: String,
        application: PluginApplicationSchema,
        adapter: PluginAdapterSchema,
        operations: [PluginOperationSchema],
        realizations: [PluginSkillRealizationSchema],
        proseSurface: PluginProseSurfaceSchema? = nil,
        codeSurface: PluginCodeSurfaceSchema? = nil,
        mediaSurface: PluginMediaSurfaceSchema? = nil,
        corpus: PluginCorpusSchema? = nil
    ) {
        self.init(
            id: id,
            version: version,
            title: title,
            application: application,
            adapters: [adapter],
            operations: operations,
            realizations: realizations,
            proseSurface: proseSurface,
            codeSurface: codeSurface,
            mediaSurface: mediaSurface,
            corpus: corpus)
    }

    public init(
        id: String,
        version: SemanticVersion = "1.0.0",
        title: String,
        application: PluginApplicationSchema,
        adapters: [PluginAdapterSchema],
        operations: [PluginOperationSchema],
        realizations: [PluginSkillRealizationSchema],
        proseSurface: PluginProseSurfaceSchema? = nil,
        codeSurface: PluginCodeSurfaceSchema? = nil,
        mediaSurface: PluginMediaSurfaceSchema? = nil,
        corpus: PluginCorpusSchema? = nil
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.application = application
        self.adapters = adapters
        self.operations = operations
        self.realizations = realizations
        self.proseSurface = proseSurface
        self.codeSurface = codeSurface
        self.mediaSurface = mediaSurface
        self.corpus = corpus
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case version
        case title
        case application
        case adapter
        case adapters
        case operations
        case realizations
        case proseSurface
        case codeSurface
        case mediaSurface
        case corpus
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(SemanticVersion.self, forKey: .version)
        title = try container.decode(String.self, forKey: .title)
        application = try container.decode(PluginApplicationSchema.self, forKey: .application)
        if let many = try container.decodeIfPresent([PluginAdapterSchema].self, forKey: .adapters) {
            adapters = many
        } else {
            adapters = [try container.decode(PluginAdapterSchema.self, forKey: .adapter)]
        }
        operations = try container.decode([PluginOperationSchema].self, forKey: .operations)
        realizations = try container.decode(
            [PluginSkillRealizationSchema].self, forKey: .realizations)
        proseSurface = try container.decodeIfPresent(
            PluginProseSurfaceSchema.self, forKey: .proseSurface)
        codeSurface = try container.decodeIfPresent(
            PluginCodeSurfaceSchema.self, forKey: .codeSurface)
        mediaSurface = try container.decodeIfPresent(
            PluginMediaSurfaceSchema.self, forKey: .mediaSurface)
        corpus = try container.decodeIfPresent(
            PluginCorpusSchema.self, forKey: .corpus)
    }

    /// Hand-written encode: omit absent optionals so digests stay stable.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(application, forKey: .application)
        // One adapter uses `adapter` so spelling does not change canonical bytes.
        if adapters.count == 1, let sole = adapters.first {
            try container.encode(sole, forKey: .adapter)
        } else {
            try container.encode(adapters, forKey: .adapters)
        }
        try container.encode(operations, forKey: .operations)
        try container.encode(realizations, forKey: .realizations)
        if let proseSurface {
            try container.encode(proseSurface, forKey: .proseSurface)
        }
        if let codeSurface {
            try container.encode(codeSurface, forKey: .codeSurface)
        }
        if let mediaSurface {
            try container.encode(mediaSurface, forKey: .mediaSurface)
        }
        if let corpus {
            try container.encode(corpus, forKey: .corpus)
        }
    }
}

public extension InstalledAdapterManifest {
    /// Predating provenance → runtime-owned generic adapter.
    var resolvedProvider: AdapterProviderProvenance {
        provider ?? AdapterProviderProvenance(
            pluginClass: .runtime,
            pluginID: adapterID.rawValue,
            pluginTitle: title)
    }
}

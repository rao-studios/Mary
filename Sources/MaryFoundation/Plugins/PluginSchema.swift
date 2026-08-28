//
//  PluginSchema.swift
//  MaryFoundation
//
//  THE WHOLE PLUGIN — the application it drives, the adapter it exports, its
//  operations, and the Skills it realizes. This is the top of the declarative
//  provider grammar; PluginValidator admits it.
//
//  A Plugin is DATA. It supplies identity and closed declarations — never
//  scripts, closures, binaries, shell commands, credentials, or a server
//  configuration. Every operation is interpreted by Mary's own compiled
//  engine, which is what makes an untrusted package safe to load: there is
//  nothing in the grammar that can express "run this".
//
//  TWO CONSEQUENCES, worth stating because they shape every package:
//
//  1. AN OPERATION CANNOT RETURN DATA. The managed-UI engine presses keys and
//     reports whether the press landed; it has no way to hand a value back.
//     Any Skill that must give the model a value — read this document, list
//     these windows — binds instead to an OBSERVATION adapter: a generic
//     compiled provider that looks at the world and answers. `proseSurface`
//     below is how a package configures one of those without shipping code.
//
//  2. A RECIPE IS A FIXED STEP ARRAY. `typeText` carries no line breaks (see
//     PluginValidator+Tokens), so multi-paragraph prose is not expressible as
//     a recipe. Writing is the typer adapter's job; recipes do the chords.
//

import Foundation

/// Maps a provider-neutral Ability Skill to one concrete Plugin operation.
///
/// This is the extension point that lets one application teach a shared
/// discipline — a text editor realizing the Writing Ability's verbs — without
/// the discipline package ever naming that application.
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

    /// Optional prose-surface layout: where this application keeps editable
    /// text, how a document is identified, and which chord makes a new one.
    ///
    /// Unlike an operation it realizes nothing and presses nothing — it
    /// configures Mary's own generic prose adapter to answer the Writing
    /// discipline's read and write Skills for this application. This is the
    /// answer to consequence (1) in the file header: a package that needs
    /// values back declares where to look rather than shipping a reader.
    public var proseSurface: PluginProseSurfaceSchema?

    /// Where this application keeps its TRANSPORT, for the same reason and by
    /// the same road: a player's state has to come back as a value, and a
    /// recipe cannot return one. See `PluginMediaSurfaceSchema`.
    public var mediaSurface: PluginMediaSurfaceSchema?

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
        mediaSurface: PluginMediaSurfaceSchema? = nil
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
            mediaSurface: mediaSurface)
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
        mediaSurface: PluginMediaSurfaceSchema? = nil
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.application = application
        self.adapters = adapters
        self.operations = operations
        self.realizations = realizations
        self.proseSurface = proseSurface
        self.mediaSurface = mediaSurface
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
        case mediaSurface
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
        mediaSurface = try container.decodeIfPresent(
            PluginMediaSurfaceSchema.self, forKey: .mediaSurface)
    }

    /// Encoding is HAND-WRITTEN, and an absent optional stays absent rather
    /// than encoding as null. The package digest is taken over these exact
    /// bytes, so a synthesized encoder emitting `"proseSurface": null` would
    /// change the digest of every package that does not declare one.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(application, forKey: .application)
        // A single adapter uses the `adapter` key, so a one-adapter package's
        // canonical bytes do not depend on which spelling the author chose.
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
        if let mediaSurface {
            try container.encode(mediaSurface, forKey: .mediaSurface)
        }
    }
}

public extension InstalledAdapterManifest {
    /// Manifests that predate explicit provenance resolve to a runtime-owned
    /// provider — a generic adapter Mary itself ships, not one a package
    /// brought with it.
    var resolvedProvider: AdapterProviderProvenance {
        provider ?? AdapterProviderProvenance(
            pluginClass: .runtime,
            pluginID: adapterID.rawValue,
            pluginTitle: title)
    }
}

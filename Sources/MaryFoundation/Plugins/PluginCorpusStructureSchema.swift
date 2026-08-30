//
//  PluginCorpusStructureSchema.swift
//  MaryFoundation
//
//  WHAT: Writing-project shape on disk — `corpus.structure` sub-block.
//  IN:   PluginCorpusSchema.structure.
//  OUT:  corpus probe / PluginValidator+Corpus.
//  PIN:  Locate-only. Names and relative paths; no write into autosaving apps.
//

import Foundation

/// How a project directory is recognised.
public enum PluginCorpusDiscovery: String, Codable, Hashable, Sendable, CaseIterable {
    /// A directory whose name ends in a known extension — `.scriv`.
    case directoryExtension
    /// Directory holding a naming file (no distinguishing extension).
    case manifestPresence
}

/// Open-state test. Drive only when open; disk read not mid-save.
public enum PluginCorpusOpenState: String, Codable, Hashable, Sendable, CaseIterable {
    /// Lock file while open. Pair with process check (crash leftover).
    case lockFile
    /// The owning application is running.
    case runningApplication
    /// Neither applies — a plain folder has no owner and is always readable.
    case alwaysOpen
}

/// How the project's outline is stored.
public enum PluginCorpusManifestKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// An XML file listing items and their nesting.
    case xmlManifest
    /// The directory tree IS the outline; an item's id is its relative path.
    case fileSystemTree
}

public enum PluginCorpusTextFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case rtf
    case plainText
    case markdown
}

/// One file an item is made of.
public struct PluginCorpusPart: Codable, Hashable, Sendable {
    /// What this part is — "text", "synopsis", "annotations".
    public var name: String
    /// Where it lives beneath the project root, with `{id}` for the item.
    public var pathTemplate: String
    public var format: PluginCorpusTextFormat

    public init(name: String, pathTemplate: String, format: PluginCorpusTextFormat) {
        self.name = name
        self.pathTemplate = pathTemplate
        self.format = format
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, pathTemplate, format
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        pathTemplate = try values.decode(String.self, forKey: .pathTemplate)
        format = try values.decode(PluginCorpusTextFormat.self, forKey: .format)
    }
}

/// Outline location and XML names (scrivx-shaped: UUID, Type, title element, Children).
public struct PluginCorpusManifest: Codable, Hashable, Sendable {
    public var kind: PluginCorpusManifestKind
    /// The manifest file, relative to the project root, with `{name}` for the
    /// project's own name. Unused for `fileSystemTree`.
    public var pathTemplate: String?
    /// The element under the document root that holds the outline.
    public var rootElement: String?
    /// The element for one item.
    public var itemElement: String?
    /// The attribute carrying an item's stable id.
    public var idAttribute: String?
    /// The child element carrying an item's title.
    public var titleElement: String?
    /// The child element wrapping an item's children.
    public var childrenElement: String?
    /// The attribute carrying an item's kind.
    public var typeAttribute: String?
    /// Kinds that are containers rather than documents.
    public var containerTypes: [String]
    /// The kind naming the manuscript root, if there is one.
    public var draftType: String?
    /// Trash kind. Contents excluded from every read.
    public var trashType: String?

    public init(
        kind: PluginCorpusManifestKind,
        pathTemplate: String? = nil,
        rootElement: String? = nil,
        itemElement: String? = nil,
        idAttribute: String? = nil,
        titleElement: String? = nil,
        childrenElement: String? = nil,
        typeAttribute: String? = nil,
        containerTypes: [String] = [],
        draftType: String? = nil,
        trashType: String? = nil
    ) {
        self.kind = kind
        self.pathTemplate = pathTemplate
        self.rootElement = rootElement
        self.itemElement = itemElement
        self.idAttribute = idAttribute
        self.titleElement = titleElement
        self.childrenElement = childrenElement
        self.typeAttribute = typeAttribute
        self.containerTypes = containerTypes
        self.draftType = draftType
        self.trashType = trashType
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, pathTemplate, rootElement, itemElement, idAttribute
        case titleElement, childrenElement, typeAttribute
        case containerTypes, draftType, trashType
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(PluginCorpusManifestKind.self, forKey: .kind)
        pathTemplate = try values.decodeIfPresent(String.self, forKey: .pathTemplate)
        rootElement = try values.decodeIfPresent(String.self, forKey: .rootElement)
        itemElement = try values.decodeIfPresent(String.self, forKey: .itemElement)
        idAttribute = try values.decodeIfPresent(String.self, forKey: .idAttribute)
        titleElement = try values.decodeIfPresent(String.self, forKey: .titleElement)
        childrenElement = try values.decodeIfPresent(String.self, forKey: .childrenElement)
        typeAttribute = try values.decodeIfPresent(String.self, forKey: .typeAttribute)
        containerTypes = try values.decodeIfPresent(
            [String].self, forKey: .containerTypes) ?? []
        draftType = try values.decodeIfPresent(String.self, forKey: .draftType)
        trashType = try values.decodeIfPresent(String.self, forKey: .trashType)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let pathTemplate { try container.encode(pathTemplate, forKey: .pathTemplate) }
        if let rootElement { try container.encode(rootElement, forKey: .rootElement) }
        if let itemElement { try container.encode(itemElement, forKey: .itemElement) }
        if let idAttribute { try container.encode(idAttribute, forKey: .idAttribute) }
        if let titleElement { try container.encode(titleElement, forKey: .titleElement) }
        if let childrenElement {
            try container.encode(childrenElement, forKey: .childrenElement)
        }
        if let typeAttribute { try container.encode(typeAttribute, forKey: .typeAttribute) }
        if !containerTypes.isEmpty {
            try container.encode(containerTypes, forKey: .containerTypes)
        }
        if let draftType { try container.encode(draftType, forKey: .draftType) }
        if let trashType { try container.encode(trashType, forKey: .trashType) }
    }
}

/// Closed structure act + menu path data. Package cannot name a seventh act.
public struct PluginCorpusCeremony: Codable, Hashable, Sendable {
    public enum Act: String, Codable, Hashable, Sendable, CaseIterable {
        case addItem
        case addContainer
        case moveToContainer
        case trash
    }

    public var act: Act
    /// Fixed menu path. `moveToContainer` last level is the user's folder at runtime.
    public var menuPath: [String]
    /// Final menu level completed from the project, not declared.
    public var completedByContainer: Bool

    public init(act: Act, menuPath: [String], completedByContainer: Bool = false) {
        self.act = act
        self.menuPath = menuPath
        self.completedByContainer = completedByContainer
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case act, menuPath, completedByContainer
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        act = try values.decode(Act.self, forKey: .act)
        menuPath = try values.decode([String].self, forKey: .menuPath)
        completedByContainer = try values.decodeIfPresent(
            Bool.self, forKey: .completedByContainer) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(act, forKey: .act)
        try container.encode(menuPath, forKey: .menuPath)
        if completedByContainer {
            try container.encode(completedByContainer, forKey: .completedByContainer)
        }
    }
}

/// A writing project's shape on disk.
public struct PluginCorpusStructureSchema: Codable, Hashable, Sendable {

    public var discovery: PluginCorpusDiscovery
    /// The directory extension that marks a project — "scriv".
    public var projectExtension: String?
    public var openState: [PluginCorpusOpenState]
    /// The lock file's path beneath the project root, for `lockFile`.
    public var lockFilePath: String?
    public var manifest: PluginCorpusManifest
    public var parts: [PluginCorpusPart]
    /// Open-item URL template. Leftover braces refuse.
    public var documentURLTemplate: String?
    /// The handle letter a spoken reference mints under — "[D3]".
    public var handlePrefix: String?
    public var ceremonies: [PluginCorpusCeremony]

    public init(
        discovery: PluginCorpusDiscovery,
        projectExtension: String? = nil,
        openState: [PluginCorpusOpenState] = [.alwaysOpen],
        lockFilePath: String? = nil,
        manifest: PluginCorpusManifest,
        parts: [PluginCorpusPart] = [],
        documentURLTemplate: String? = nil,
        handlePrefix: String? = nil,
        ceremonies: [PluginCorpusCeremony] = []
    ) {
        self.discovery = discovery
        self.projectExtension = projectExtension
        self.openState = openState
        self.lockFilePath = lockFilePath
        self.manifest = manifest
        self.parts = parts
        self.documentURLTemplate = documentURLTemplate
        self.handlePrefix = handlePrefix
        self.ceremonies = ceremonies
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case discovery, projectExtension, openState, lockFilePath
        case manifest, parts, documentURLTemplate, handlePrefix, ceremonies
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        discovery = try values.decode(PluginCorpusDiscovery.self, forKey: .discovery)
        projectExtension = try values.decodeIfPresent(
            String.self, forKey: .projectExtension)
        openState = try values.decodeIfPresent(
            [PluginCorpusOpenState].self, forKey: .openState) ?? [.alwaysOpen]
        lockFilePath = try values.decodeIfPresent(String.self, forKey: .lockFilePath)
        manifest = try values.decode(PluginCorpusManifest.self, forKey: .manifest)
        parts = try values.decodeIfPresent([PluginCorpusPart].self, forKey: .parts) ?? []
        documentURLTemplate = try values.decodeIfPresent(
            String.self, forKey: .documentURLTemplate)
        handlePrefix = try values.decodeIfPresent(String.self, forKey: .handlePrefix)
        ceremonies = try values.decodeIfPresent(
            [PluginCorpusCeremony].self, forKey: .ceremonies) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(discovery, forKey: .discovery)
        if let projectExtension {
            try container.encode(projectExtension, forKey: .projectExtension)
        }
        if openState != [.alwaysOpen] { try container.encode(openState, forKey: .openState) }
        if let lockFilePath { try container.encode(lockFilePath, forKey: .lockFilePath) }
        try container.encode(manifest, forKey: .manifest)
        if !parts.isEmpty { try container.encode(parts, forKey: .parts) }
        if let documentURLTemplate {
            try container.encode(documentURLTemplate, forKey: .documentURLTemplate)
        }
        if let handlePrefix { try container.encode(handlePrefix, forKey: .handlePrefix) }
        if !ceremonies.isEmpty { try container.encode(ceremonies, forKey: .ceremonies) }
    }
}

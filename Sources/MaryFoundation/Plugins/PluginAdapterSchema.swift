//
//  PluginAdapterSchema.swift
//  MaryFoundation
//
//  WHAT: Adapter a Plugin exports — operation surface as data, not compiled code.
//  IN:   PluginSchema.adapters.
//  OUT:  PluginValidator+Operations, AbilityRuntime dispatch.
//

import Foundation

public struct PluginAdapterSchema: Codable, Hashable, Sendable {
    public var id: AdapterID
    public var version: SemanticVersion
    public var title: String
    public var engine: PluginEngine
    /// Requested permissions are compared with live machine grants. A package
    /// cannot grant itself Accessibility or any other privilege.
    public var permissions: [PermissionKind]

    public init(
        id: AdapterID,
        version: SemanticVersion = "1.0.0",
        title: String,
        engine: PluginEngine = .macUI,
        permissions: [PermissionKind] = [.accessibility]
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.engine = engine
        self.permissions = permissions
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case version
        case title
        case engine
        case permissions
        // Legacy executable content is named only so decoding can reject it;
        // it is deliberately not represented in Mary's value model.
        case scriptingRuntime
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AdapterID.self, forKey: .id)
        version = try container.decode(SemanticVersion.self, forKey: .version)
        title = try container.decode(String.self, forKey: .title)
        if container.contains(.scriptingRuntime) {
            throw DecodingError.dataCorruptedError(
                forKey: .scriptingRuntime,
                in: container,
                debugDescription: "Plugins are data-only; executable scripting runtimes are not supported.")
        }
        let engineName = try container.decode(String.self, forKey: .engine)
        guard let decodedEngine = PluginEngine(rawValue: engineName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .engine,
                in: container,
                debugDescription: "Plugins must use Mary's native macUI interpreter.")
        }
        engine = decodedEngine
        permissions = try container.decode([PermissionKind].self, forKey: .permissions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(engine, forKey: .engine)
        try container.encode(permissions, forKey: .permissions)
    }
}

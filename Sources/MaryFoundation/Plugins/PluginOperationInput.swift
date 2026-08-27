//
//  PluginOperationInput.swift
//  MaryFoundation
//
//  The typed, bounded inputs a declarative operation accepts. Inputs are the
//  only way caller data enters a recipe.
//

import Foundation

public enum PluginOperationInputKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case number
    case integer
    case boolean

    public var modelType: String {
        switch self {
        case .text: return "string"
        case .number: return "number"
        case .integer: return "integer"
        case .boolean: return "boolean"
        }
    }
}

/// The adapter-side argument contract. Values remain strings at the legacy
/// provider boundary, but the recipe interpreter validates and converts them
/// according to this closed declaration before issuing any event.
public struct PluginOperationInputSchema: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var kind: PluginOperationInputKind
    public var required: Bool
    public var defaultValue: String?
    public var minimum: Double?
    public var maximum: Double?
    public var enumValues: [String]

    public init(
        name: String,
        kind: PluginOperationInputKind,
        required: Bool = true,
        defaultValue: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        enumValues: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.enumValues = enumValues
    }

    public var id: String { name }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case kind
        case required
        case defaultValue
        case minimum
        case maximum
        case enumValues
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(PluginOperationInputKind.self, forKey: .kind)
        required = try values.decode(Bool.self, forKey: .required)
        defaultValue = try values.decodeIfPresent(String.self, forKey: .defaultValue)
        minimum = try values.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try values.decodeIfPresent(Double.self, forKey: .maximum)
        enumValues = try values.decode([String].self, forKey: .enumValues)
    }
}

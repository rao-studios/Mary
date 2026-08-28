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
        // ⚠️ `decodeIfPresent`, and it was `decode` until the first package
        // ever to declare an operation input tried to load. An input with no
        // closed list of values is the ordinary case — a search query, a
        // title — and its author writes no `enumValues` key, which is exactly
        // what the memberwise initializer's own default says is fine. The
        // decoder disagreed, and the failure it produced named no field:
        // "The data couldn't be read because it is missing."
        //
        // It survived this long because nothing shipped had an operation
        // input at all. Same shape as the `chords` map that encoded as a flat
        // array: machinery that is correct in every direction nobody has
        // travelled.
        enumValues = try values.decodeIfPresent([String].self, forKey: .enumValues) ?? []
    }

    /// Hand-written so an absent list stays absent — the synthesized encoder
    /// would write `"enumValues": []` into every input, and the package
    /// digest is taken over these exact bytes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(required, forKey: .required)
        if let defaultValue { try container.encode(defaultValue, forKey: .defaultValue) }
        if let minimum { try container.encode(minimum, forKey: .minimum) }
        if let maximum { try container.encode(maximum, forKey: .maximum) }
        if !enumValues.isEmpty { try container.encode(enumValues, forKey: .enumValues) }
    }
}

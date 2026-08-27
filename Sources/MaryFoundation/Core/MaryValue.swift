import Foundation

/// A provider-independent runtime value. The encoding is ordinary JSON so a
/// Value can cross XPC, Bluetooth, files, or a model-provider boundary without
/// inheriting any transport's argument representation.
public indirect enum MaryValue: Hashable, Sendable {
    case null
    case string(String)
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case object([String: MaryValue])
    case array([MaryValue])
    case data(Data)

    public var objectValue: [String: MaryValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

extension MaryValue: Codable {
    private static let dataKey = "$mary.data"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MaryValue].self) {
            self = .array(value)
        } else {
            let value = try container.decode([String: MaryValue].self)
            if value.count == 1,
               case .string(let encoded)? = value[Self.dataKey],
               let bytes = Data(base64Encoded: encoded) {
                self = .data(bytes)
            } else {
                self = .object(value)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .string(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: encoder.codingPath, debugDescription: "Mary numbers must be finite."))
            }
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .data(let value):
            try container.encode([Self.dataKey: MaryValue.string(value.base64EncodedString())])
        }
    }
}


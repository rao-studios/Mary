//
//  StrictDecoding.swift
//  MaryFoundation
//
//  WHAT: Reject unknown object keys before reading values.
//  IN:   AbilityPackageCodec / StyleProfileCodec keyed decode.
//  OUT:  DecodingError at the `.mary` boundary.
//  PIN:  Synthesized Codable would drop bytes the digest must cover.
//

import Foundation

/// CodingKey that surfaces every JSON member so it can be compared to closed `CodingKeys`.
struct StrictDecodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Decoder {
    /// First undeclared member → fail, before digest is taken over the model.
    func rejectUnknownKeys<Keys>(_ keys: Keys.Type) throws
    where Keys: CodingKey & CaseIterable {
        let values = try container(keyedBy: StrictDecodingKey.self)
        let allowed = Set(Keys.allCases.map(\.stringValue))
        guard let unknown = values.allKeys.first(where: {
            !allowed.contains($0.stringValue)
        }) else { return }

        throw DecodingError.dataCorrupted(.init(
            codingPath: codingPath + [unknown],
            debugDescription: "Unknown key '\(unknown.stringValue)' is not allowed in a .mary package."))
    }
}

import Foundation

/// A key that accepts every JSON object member so a decoder can compare the
/// actual wire shape with a type's closed `CodingKeys` set. Swift's synthesized
/// `Codable` intentionally ignores unknown members; `.mary` files cannot,
/// because ignored bytes would also be absent from the verified digest.
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
    /// Rejects the first object member not declared by `Keys`. Call this before
    /// reading any values so executable-looking additions fail at the decoding
    /// boundary, before integrity is evaluated over the decoded value model.
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

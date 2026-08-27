//
//  AbilityPackageCodec.swift
//  MaryFoundation
//
//  READING AND WRITING A `.mary` FILE. Every byte that is decoded is also
//  covered by the integrity digest, so unknown members are a decode failure
//  rather than something quietly dropped (see StrictDecoding.swift).
//

import CryptoKit
import Foundation

public enum AbilityPackageCodec {
    /// Ability packages are declarative routing graphs, not asset archives.
    /// Four MiB leaves ample room for large graphs while bounding imported
    /// JSON decoding and integrity work.
    public static let maximumPackageBytes = 4 * 1_024 * 1_024

    public enum CodecError: LocalizedError, Equatable {
        case invalidExtension
        case packageTooLarge
        case unsupportedDigestAlgorithm
        case malformedDigest
        case digestMismatch
        case incompleteSignature
        case invalidSignature
        case unsupportedSignatureAlgorithm

        public var errorDescription: String? {
            switch self {
            case .invalidExtension: return "Ability packages must use the .mary extension."
            case .packageTooLarge:
                return "Ability packages cannot exceed \(AbilityPackageCodec.maximumPackageBytes) bytes."
            case .unsupportedDigestAlgorithm: return "Ability packages currently require a SHA-256 digest."
            case .malformedDigest: return "The package digest must be 64 hexadecimal SHA-256 characters."
            case .digestMismatch: return "The package digest does not match its contents."
            case .incompleteSignature: return "The package signature metadata is incomplete."
            case .invalidSignature: return "The package signature is not valid."
            case .unsupportedSignatureAlgorithm: return "The package uses an unsupported signature algorithm."
            }
        }
    }

    public static func decode(_ data: Data, verifyIntegrity: Bool = true) throws -> MaryAbilityPackage {
        guard data.count <= maximumPackageBytes else { throw CodecError.packageTooLarge }
        let package = try decoder.decode(MaryAbilityPackage.self, from: data)
        if verifyIntegrity { try verify(package) }
        return package
    }

    public static func load(from url: URL, verifyIntegrity: Bool = true) throws -> MaryAbilityPackage {
        try decode(contents(of: url), verifyIntegrity: verifyIntegrity)
    }

    /// Reads the exact portable package bytes without allowing a file on disk
    /// to allocate beyond the codec's import boundary.
    public static func contents(of url: URL) throws -> Data {
        guard url.pathExtension.lowercased() == "mary" else { throw CodecError.invalidExtension }
        return try boundedData(from: url)
    }

    /// Encodes canonical, sorted JSON and refreshes the digest. Saving an
    /// edited package deliberately drops a stale signature; callers may sign
    /// the resulting package as a separate, explicit operation.
    public static func encoded(
        _ package: MaryAbilityPackage,
        prettyPrinted: Bool = true
    ) throws -> Data {
        var copy = package
        let digest = try digest(of: copy)
        copy.integrity = AbilityPackageIntegrity(digest: digest)
        return try encode(copy, prettyPrinted: prettyPrinted)
    }

    public static func signed(
        _ package: MaryAbilityPackage,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> MaryAbilityPackage {
        var copy = package
        copy.integrity = nil
        let canonical = try canonicalData(copy)
        let digest = SHA256.hash(data: canonical)
        let signature = try privateKey.signature(for: Data(digest))
        copy.integrity = AbilityPackageIntegrity(
            digest: digest.hex,
            signatureAlgorithm: "ed25519",
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            signature: signature.base64EncodedString())
        return copy
    }

    public static func verify(_ package: MaryAbilityPackage) throws {
        guard let integrity = package.integrity else { return }
        guard integrity.algorithm.lowercased() == "sha256" else {
            throw CodecError.unsupportedDigestAlgorithm
        }
        guard integrity.digest.count == 64,
              integrity.digest.allSatisfy(\.isHexDigit) else {
            throw CodecError.malformedDigest
        }
        let expected = try digest(of: package)
        guard expected == integrity.digest.lowercased() else { throw CodecError.digestMismatch }
        guard integrity.isSigned else {
            if integrity.signatureAlgorithm != nil
                || integrity.publicKey != nil
                || integrity.signature != nil {
                throw CodecError.incompleteSignature
            }
            return
        }
        guard integrity.signatureAlgorithm?.lowercased() == "ed25519" else {
            throw CodecError.unsupportedSignatureAlgorithm
        }
        guard let keyText = integrity.publicKey,
              let signatureText = integrity.signature,
              let keyData = Data(base64Encoded: keyText),
              let signatureData = Data(base64Encoded: signatureText),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let digestData = Data(hex: expected),
              publicKey.isValidSignature(signatureData, for: digestData)
        else { throw CodecError.invalidSignature }
    }

    public static func digest(of package: MaryAbilityPackage) throws -> String {
        var unsigned = package
        unsigned.integrity = nil
        return SHA256.hash(data: try canonicalData(unsigned)).hex
    }

    public static func canonicalData(_ package: MaryAbilityPackage) throws -> Data {
        try encode(package, prettyPrinted: false)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func boundedData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(maximumPackageBytes, 64 * 1_024))
        while data.count <= maximumPackageBytes {
            let remaining = maximumPackageBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty
            else { return data }
            data.append(chunk)
        }
        throw CodecError.packageTooLarge
    }

    private static func encode(
        _ package: MaryAbilityPackage,
        prettyPrinted: Bool
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(package)
        if prettyPrinted { data.append(0x0A) }
        return data
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

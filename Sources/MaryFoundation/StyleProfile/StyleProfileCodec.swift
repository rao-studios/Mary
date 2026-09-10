//
//  StyleProfileCodec.swift
//  MaryFoundation
//
//  WHAT: Read/write `.marystyle`. Same digest/bounded-reader discipline as AbilityPackageCodec.
//  IN:   files / Data.
//  OUT:  StyleProfile, ThreadContextStore.loadStyleProfile.
//

import CryptoKit
import Foundation

public enum StyleProfileCodec {

    /// Import cap for decode + integrity.
    public static let maximumProfileBytes = 512 * 1_024
    public static let fileExtension = "marystyle"

    public enum CodecError: LocalizedError, Equatable {
        case invalidExtension
        case profileTooLarge
        case unsupportedFormat
        case unsupportedFormatVersion
        case unsupportedDigestAlgorithm
        case malformedDigest
        case digestMismatch
        case incompleteSignature
        case invalidSignature
        case unsupportedSignatureAlgorithm

        public var errorDescription: String? {
            switch self {
            case .invalidExtension:
                return "Style profiles must use the .\(StyleProfileCodec.fileExtension) extension."
            case .profileTooLarge:
                return "Style profiles cannot exceed \(StyleProfileCodec.maximumProfileBytes) bytes."
            case .unsupportedFormat:
                return "That file is not a Mary style profile."
            case .unsupportedFormatVersion:
                return "That style profile was written in a format this Mary does not use."
            case .unsupportedDigestAlgorithm:
                return "Style profiles currently require a SHA-256 digest."
            case .malformedDigest:
                return "The profile digest must be 64 hexadecimal SHA-256 characters."
            case .digestMismatch:
                return "The profile digest does not match its contents."
            case .incompleteSignature:
                return "The profile signature metadata is incomplete."
            case .invalidSignature:
                return "The profile signature is not valid."
            case .unsupportedSignatureAlgorithm:
                return "The profile uses an unsupported signature algorithm."
            }
        }
    }

    public static func decode(
        _ data: Data, verifyIntegrity: Bool = true
    ) throws -> StyleProfile {
        guard data.count <= maximumProfileBytes else { throw CodecError.profileTooLarge }
        let profile = try decoder.decode(StyleProfile.self, from: data)
        guard profile.format == StyleProfile.format else { throw CodecError.unsupportedFormat }
        // Exact formatVersion. ThreadContextStore.loadStyleProfile uses try? → empty corpus.
        guard profile.formatVersion == StyleProfile.currentFormatVersion else {
            throw CodecError.unsupportedFormatVersion
        }
        if verifyIntegrity { try verify(profile) }
        return profile
    }

    public static func load(from url: URL, verifyIntegrity: Bool = true) throws -> StyleProfile {
        try decode(contents(of: url), verifyIntegrity: verifyIntegrity)
    }

    public static func contents(of url: URL) throws -> Data {
        guard url.pathExtension.lowercased() == fileExtension else {
            throw CodecError.invalidExtension
        }
        return try boundedData(from: url)
    }

    /// Canonical bytes + refreshed digest. Drops a stale signature.
    public static func encoded(
        _ profile: StyleProfile, prettyPrinted: Bool = true
    ) throws -> Data {
        var copy = profile
        copy.integrity = AbilityPackageIntegrity(digest: try digest(of: copy))
        return try encode(copy, prettyPrinted: prettyPrinted)
    }

    public static func signed(
        _ profile: StyleProfile, privateKey: Curve25519.Signing.PrivateKey
    ) throws -> StyleProfile {
        var copy = profile
        copy.integrity = nil
        let canonical = try canonicalData(copy)
        let digest = SHA256.hash(data: canonical)
        let signature = try privateKey.signature(for: Data(digest))
        copy.integrity = AbilityPackageIntegrity(
            digest: digest.styleHex,
            signatureAlgorithm: "ed25519",
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            signature: signature.base64EncodedString())
        return copy
    }

    public static func verify(_ profile: StyleProfile) throws {
        guard let integrity = profile.integrity else { return }
        guard integrity.algorithm.lowercased() == "sha256" else {
            throw CodecError.unsupportedDigestAlgorithm
        }
        guard integrity.digest.count == 64,
              integrity.digest.allSatisfy(\.isHexDigit) else {
            throw CodecError.malformedDigest
        }
        let expected = try digest(of: profile)
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
              let digestData = Data(styleHex: expected),
              publicKey.isValidSignature(signatureData, for: digestData)
        else { throw CodecError.invalidSignature }
    }

    public static func digest(of profile: StyleProfile) throws -> String {
        var unsigned = profile
        unsigned.integrity = nil
        return SHA256.hash(data: try canonicalData(unsigned)).styleHex
    }

    public static func canonicalData(_ profile: StyleProfile) throws -> Data {
        try encode(profile, prettyPrinted: false)
    }

    // MARK: - Import

    /// Import: drop project tenets, mark `.imported`, reset evidence to candidate.
    public static func rekeyForImport(
        _ profile: StyleProfile, from origin: String, at now: Date
    ) -> StyleProfile {
        let imported = profile.transferable.map { tenet -> StyleTenet in
            StyleTenet(
                dimension: tenet.dimension,
                value: tenet.value,
                scope: tenet.scope,
                support: 0,
                counter: 0,
                confidence: 0,
                status: .candidate,
                provenance: .imported(from: origin),
                lastObservedAt: now,
                vocabulary: tenet.vocabulary,
                statement: tenet.statement,
                illustration: tenet.illustration)
        }
        return StyleProfile(
            profile: .init(
                subject: profile.profile.subject,
                version: profile.profile.version,
                publisher: profile.profile.publisher,
                summary: profile.profile.summary,
                minimumMaryVersion: profile.profile.minimumMaryVersion,
                createdAt: profile.profile.createdAt,
                updatedAt: now),
            tenets: imported)
    }

    // MARK: - Internals

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func boundedData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(maximumProfileBytes, 64 * 1_024))
        while data.count <= maximumProfileBytes {
            let remaining = maximumProfileBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty
            else { return data }
            data.append(chunk)
        }
        throw CodecError.profileTooLarge
    }

    private static func encode(_ profile: StyleProfile, prettyPrinted: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(profile)
        if prettyPrinted { data.append(0x0A) }
        return data
    }
}

private extension Digest {
    var styleHex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    init?(styleHex: String) {
        let characters = Array(styleHex)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}

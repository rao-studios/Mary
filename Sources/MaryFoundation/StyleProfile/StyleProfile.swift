//
//  StyleProfile.swift
//  MaryFoundation
//
//  WHAT: Portable `.marystyle` envelope — versioned JSON, digest, optional signature.
//  IN:   StyleProfileCodec. OUT: StyleTenet list, StyleRendering.
//  PIN:  No credentials, Interactions, Thread, source, closures, adapters.
//        Signature ≠ speak permission; StyleProvenance does.
//

import Foundation

public struct StyleProfileMetadata: Codable, Hashable, Sendable {
    /// AbilityID raw value. Craft, not the application where it was observed.
    public var subject: String
    public var version: SemanticVersion
    public var publisher: String
    public var summary: String
    public var minimumMaryVersion: SemanticVersion?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        subject: String,
        version: SemanticVersion,
        publisher: String = "",
        summary: String = "",
        minimumMaryVersion: SemanticVersion? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.subject = subject
        self.version = version
        self.publisher = publisher
        self.summary = summary
        self.minimumMaryVersion = minimumMaryVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StyleProfile: Codable, Hashable, Sendable {

    public static let format = "mary.style-profile"
    /// Format version. Older builds refuse newer documents rather than misread.
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var profile: StyleProfileMetadata
    public var tenets: [StyleTenet]
    /// Vetoed keys (muffle, not delete). Omitted when empty for old digests.
    public var vetoedTenetKeys: [String]?
    public var integrity: AbilityPackageIntegrity?

    public init(
        format: String = StyleProfile.format,
        formatVersion: Int = StyleProfile.currentFormatVersion,
        profile: StyleProfileMetadata,
        tenets: [StyleTenet],
        vetoedTenetKeys: [String]? = nil,
        integrity: AbilityPackageIntegrity? = nil
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.profile = profile
        // Sorted by key — digest must be reproducible.
        self.tenets = tenets.sorted { $0.tenetKey < $1.tenetKey }
        // Empty vetoes omitted — one encoding.
        let vetoed = (vetoedTenetKeys ?? []).sorted()
        self.vetoedTenetKeys = vetoed.isEmpty ? nil : vetoed
        self.integrity = integrity
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case format, formatVersion, profile, tenets, vetoedTenetKeys, integrity
    }

    /// Strict decode (StrictDecoding). Signed artifact cannot drop unknown keys.
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        profile = try container.decode(StyleProfileMetadata.self, forKey: .profile)
        tenets = try container.decode([StyleTenet].self, forKey: .tenets)
            .sorted { $0.tenetKey < $1.tenetKey }
        let vetoed = try container.decodeIfPresent([String].self, forKey: .vetoedTenetKeys)
        vetoedTenetKeys = (vetoed?.isEmpty ?? true) ? nil : vetoed?.sorted()
        integrity = try container.decodeIfPresent(
            AbilityPackageIntegrity.self, forKey: .integrity)
    }

    /// Tenets this build may act on.
    public var renderable: [StyleTenet] { tenets.filter(\.isRenderable) }

    /// Transferable scopes. Import rewrites provenance; project tenets drop.
    public var transferable: [StyleTenet] {
        tenets.filter { $0.isMeaningful && $0.scope.kind.isTransferable }
    }
}

/// One canonicalizer + hash. Sibling: UnitIndexHashing.
public enum StyleHashing {

    /// Collapse whitespace, lowercase, keep punctuation.
    public static func canonical(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// FNV-1a 64. Not Hasher (per-process seed).
    public static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

//
//  StyleProfile.swift
//  MaryFoundation
//
//  THE PORTABLE ARTIFACT. Modelled directly on the `.mary` envelope, because
//  that format already solves this exact problem: a self-describing versioned
//  document, canonical sorted JSON, a self-excluding SHA-256 digest, an
//  optional Ed25519 signature, and strict decoding so unknown bytes cannot sit
//  outside the thing the digest covers.
//
//  WHAT IT DELIBERATELY DOES NOT CONTAIN: credentials, raw Interactions,
//  Totem memory, source code, closures, or adapter binaries — the same
//  exclusion list the `.mary` exchange unit carries, for the same reason.
//  The source-code half is not a restriction to work around; it is what makes
//  the artifact worth having. A profile carries how you write, never what you
//  wrote, so you can hand someone your style without handing them your code.
//
//  A signature proves the bytes match the embedded key. It is NOT an
//  authorization level, exactly as `AbilityRuntimeSnapshot` says of packages —
//  and it is emphatically not what decides whether a tenet may speak. That is
//  `StyleProvenance`, and an imported tenet stays inert however well signed.
//

import Foundation

public struct StyleProfileMetadata: Codable, Hashable, Sendable {
    /// The subject this profile describes — an `AbilityID` raw value.
    ///
    /// THE ABILITY, NOT THE APPLICATION. Xcode is not what is being learned
    /// about; coding is, and Xcode is where it was observed. Keying the
    /// document by ability is what lets a second editor realizing the same
    /// craft read what the first one learned, and what makes the artifact
    /// answer "how do you write" rather than "how do you use this app".
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
    /// ONE FORMAT, AND NO HISTORY BEHIND IT.
    ///
    /// This briefly counted to 3, carrying a staged migration for shapes that
    /// only ever existed on one development machine. Nothing has shipped, so
    /// every document those branches could read was written hours earlier by an
    /// earlier build — and the corpus is re-derivable
    /// (`StyleRecency.decayFloor`'s note: a tenet is a projection of files that
    /// still exist), which makes discarding an unreadable one cost seconds of
    /// settling and makes migration the expensive way to save it.
    ///
    /// The field itself stays, and earns its line: it is what stops an older
    /// build from silently misreading a newer document, which is the failure
    /// with no symptom. It is also what a portable artifact needs the day this
    /// does travel between totems.
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var profile: StyleProfileMetadata
    public var tenets: [StyleTenet]
    /// Tenet keys the user has vetoed, carried so the veto survives a
    /// relaunch. The vetoed tenets themselves ARE in `tenets` — a veto is a
    /// muffle, not a deletion, and lifting it after a restore must still have
    /// evidence to reveal. Optional and omitted when empty, so profiles
    /// written before it existed read (and re-verify) unchanged.
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
        // Sorted by key so the same profile encodes to the same bytes twice.
        // A digest over an order-dependent array is not reproducible, and an
        // artifact whose digest depends on dictionary iteration order cannot
        // be verified on the machine that receives it.
        self.tenets = tenets.sorted { $0.tenetKey < $1.tenetKey }
        // Same reproducibility rule, and empty collapses to absent so "no
        // vetoes" has exactly one encoding.
        let vetoed = (vetoedTenetKeys ?? []).sorted()
        self.vetoedTenetKeys = vetoed.isEmpty ? nil : vetoed
        self.integrity = integrity
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case format, formatVersion, profile, tenets, vetoedTenetKeys, integrity
    }

    /// Strict, for the reason `StrictDecoding.swift` gives: ignored members
    /// would also be absent from the verified digest, so an unknown key is a
    /// decode failure rather than something quietly dropped.
    ///
    /// This is the deliberate opposite of the additive tolerance a wire
    /// protocol needs. A signed artifact cannot accept unknown fields; a
    /// versioned transport must. Both rules are right in their own place.
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

    /// Tenets this build understands and may act on.
    public var renderable: [StyleTenet] { tenets.filter(\.isRenderable) }

    /// What may be carried to another machine: transferable scopes only, and
    /// with observation provenance rewritten at the far end on import. Project
    /// tenets are dropped — they describe one repository's furniture.
    public var transferable: [StyleTenet] {
        tenets.filter { $0.isMeaningful && $0.scope.kind.isTransferable }
    }
}

/// One canonicalizer and one hash for everything tenet-addressed, for the same
/// reason `UnitIndexHashing` exists on the ambient side: three spellings
/// already exist in this codebase and they disagree, and a key minted on one
/// machine must resolve on another.
public enum StyleHashing {

    /// Collapse whitespace, lowercase, keep punctuation. Punctuation survives
    /// because a path separator and a hyphen are meaning, not noise.
    public static func canonical(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// FNV-1a 64. Deliberately not `Hasher`, which is per-process seeded — an
    /// address that changed every launch would be wrong in the way that is
    /// hardest to notice, because everything would still appear to work.
    public static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

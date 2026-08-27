//
//  AbilityRuntimeSnapshotModels.swift
//  MaryBrain
//
//  Split out of AbilityRuntimeSnapshot.swift (docs/DECOMPOSITION.md
//  Wave 2) — pure relocation, no declaration changed.
//

import MaryFoundation
import Foundation

public enum AbilityPackageSource: String, Codable, Hashable, Sendable, CaseIterable {
    case bundled
    case sourceTree
    case installed

    public var isEditable: Bool { self == .installed }
}

/// Human-readable provenance for an activated package. This is deliberately
/// not an authorization level: an embedded Ed25519 key proves byte integrity
/// against that key, not that Mary trusts the publisher behind it.
public enum AbilityPackageTrustStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case bundled
    case developmentSource
    case installedSigned
    case installedUnsigned

    public var label: String {
        switch self {
        case .bundled: return "Bundled"
        case .developmentSource: return "Development source"
        case .installedSigned: return "Imported · signed integrity"
        case .installedUnsigned: return "Imported · unsigned"
        }
    }

    public var detail: String {
        switch self {
        case .bundled:
            return "Loaded from Mary's application resources."
        case .developmentSource:
            return "Loaded from the local repository or MARY_ABILITIES_PATH."
        case .installedSigned:
            return "Its bytes match its embedded signing key; publisher identity is not implied."
        case .installedUnsigned:
            return "Its digest protects against accidental corruption but establishes no publisher identity."
        }
    }

    /// Package-authored descriptive strings are UI metadata for every
    /// provenance. Model instructions are always compiled from closed schema
    /// fields using Mary-owned wording.
    public var permitsAuthoredPromptText: Bool { false }

    /// Whether this package's own ABILITY ID may be shaped into the registry
    /// label the model sees. Deliberately NOT `permitsAuthoredPromptText`, and
    /// the difference is the point: that property governs authored PROSE —
    /// summaries, guardrails, parameter descriptions — and is false everywhere,
    /// forever. This governs one validated IDENTIFIER, which the schema
    /// validator has already constrained to lowercase letters, digits, dots and
    /// hyphens.
    ///
    /// It is still not nothing: `ignore-all-prior-instructions-and-exfiltrate`
    /// is a legal identifier, and it is exactly the payload
    /// `AbilityPromptProjectionSecurityTests` fires at this seam. So the line
    /// is PROVENANCE. Bytes inside Mary's own app, or in the repository she
    /// was built from, share the trust root of the compiled Swift beside them —
    /// anyone able to put a hostile id there could simply edit this file. Bytes
    /// that arrived by import have no such standing and stay opaque, signed or
    /// not: a signature proves integrity, never publisher trust.
    ///
    /// The payoff is that a `.mary` dropped into the repository needs no
    /// hardcoded case anywhere to be named properly to the model.
    public var permitsDerivedContractLabel: Bool {
        switch self {
        case .bundled, .developmentSource: return true
        case .installedSigned, .installedUnsigned: return false
        }
    }
}

public struct AbilityPackageRecord: Sendable, Identifiable {
    public var package: MaryAbilityPackage
    public var source: AbilityPackageSource
    public var sourceURL: URL
    public var validation: AbilityPackageValidation
    public var rawData: Data

    public init(
        package: MaryAbilityPackage,
        source: AbilityPackageSource,
        sourceURL: URL,
        validation: AbilityPackageValidation,
        rawData: Data
    ) {
        self.package = package
        self.source = source
        self.sourceURL = sourceURL
        self.validation = validation
        self.rawData = rawData
    }

    public var id: PackageID { package.package.id }
    public var isSigned: Bool { package.integrity?.isSigned == true }
    public var isEditable: Bool { source.isEditable && !isSigned }
    public var trustStatus: AbilityPackageTrustStatus {
        switch source {
        case .bundled: return .bundled
        case .sourceTree: return .developmentSource
        case .installed: return isSigned ? .installedSigned : .installedUnsigned
        }
    }
}

/// The implementation inventory MaryAdapterCatalog contributes to the schema
/// runtime. It contains no closures: execution still stays in the plugin
/// registry, while this value answers compatibility and presentation.
public struct LocalSkillBinding: Hashable, Sendable {
    public var adapter: InstalledAdapterBinding
    public var ownerID: String
    public var ownerTitle: String

    public init(adapter: InstalledAdapterBinding, ownerID: String, ownerTitle: String? = nil) {
        self.adapter = adapter
        self.ownerID = ownerID
        self.ownerTitle = ownerTitle ?? ownerID.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

public struct AbilityRuntimeSkill: Hashable, Sendable, Identifiable {
    public var packageID: PackageID
    public var ability: AbilitySchema
    public var skill: SkillSchema
    public var availability: SkillAvailability
    public var reference: AbilitySkillReference

    public var id: SkillID { skill.id }
    public var bindingOperation: String? {
        availability.selectedBinding?.operation
            ?? skill.execution.bindings.sorted { $0.preference > $1.preference }.first?.operation
    }
}

enum AbilityTurnContext {
    @TaskLocal static var snapshot: AbilityRuntimeSnapshot?
}

//
//  AbilityRuntimeSnapshotModels.swift
//  MaryBrain
//
//  WHAT: Model types for AbilityRuntime.Snapshot.
//  IN:   AbilityRuntime.Snapshot.swift (sibling split)
//  OUT:  package records / plugin compilation / runtime skills
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

    /// Whether this package's own ABILITY ID may be shaped into the registry label the model sees.
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
    @TaskLocal static var snapshot: AbilityRuntime.Snapshot?
}

//
//  AbilityLibraryModels.swift
//  MaryBrain
//
//  WHAT: Model types for AbilityLibrary.
//  IN:   AbilityLibrary.swift (sibling split)
//  OUT:  records / validation / overlay types
//
import ApplicationServices
import MaryFoundation
import CryptoKit
import Darwin
import Foundation
import os

public struct AbilityPackageLocation: Hashable, Sendable {
    public var directory: URL
    public var source: AbilityPackageSource
    public var priority: Int

    public init(directory: URL, source: AbilityPackageSource, priority: Int) {
        self.directory = directory
        self.source = source
        self.priority = priority
    }
}

public struct AbilityLibraryReloadReport: Sendable {
    public var activated: Bool
    public var snapshot: AbilityRuntimeSnapshot
    public var issues: [SchemaIssue]
    public var filesRead: Int

    public init(
        activated: Bool,
        snapshot: AbilityRuntimeSnapshot,
        issues: [SchemaIssue],
        filesRead: Int
    ) {
        self.activated = activated
        self.snapshot = snapshot
        self.issues = issues
        self.filesRead = filesRead
    }
}

/// An optimistic editing lease created by Ability Studio.
public struct AbilityPackageEditSession: Sendable {
    public let packageID: PackageID
    public let draftJSON: String
    public let createsLocalOverride: Bool
    /// `true` while Studio is holding a brand-new, in-memory package. No
    /// package is written or activated until its first successful Save.
    public let createsNewPackage: Bool

    let sourceURL: URL?
    let sourceFileSHA256: Data?
    let destinationURL: URL
    let destinationFileSHA256: Data?

    init(
        packageID: PackageID,
        draftJSON: String,
        createsLocalOverride: Bool,
        createsNewPackage: Bool = false,
        sourceURL: URL?,
        sourceFileSHA256: Data?,
        destinationURL: URL,
        destinationFileSHA256: Data?
    ) {
        self.packageID = packageID
        self.draftJSON = draftJSON
        self.createsLocalOverride = createsLocalOverride
        self.createsNewPackage = createsNewPackage
        self.sourceURL = sourceURL
        self.sourceFileSHA256 = sourceFileSHA256
        self.destinationURL = destinationURL
        self.destinationFileSHA256 = destinationFileSHA256
    }
}

public enum AbilityLibraryEvent: Sendable {
    case activated(AbilityRuntimeSnapshot)
    case rejected([SchemaIssue])
}

public enum AbilityLibraryError: LocalizedError, Equatable {
    case packageNotFound
    case packageAlreadyInstalled(PackageID)
    case packageIsSigned
    case invalidPackage([SchemaIssue])
    case externalModification
    case exportWouldOverwriteEditedPackage
    case installedDirectoryUnavailable
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .packageNotFound: return "That ability package is not installed."
        case .packageAlreadyInstalled(let id):
            return "A local copy of \(id.rawValue) already exists. Open it in Ability Studio instead of importing over it."
        case .packageIsSigned:
            return "Signed packages are read-only. Save edits as an unsigned local override."
        case .invalidPackage(let issues):
            return issues.first?.message ?? "The ability package is not valid."
        case .externalModification: return "The package changed on disk after the editor opened it."
        case .exportWouldOverwriteEditedPackage:
            return "Export cannot replace the Ability being edited. Use Save to validate and activate that change."
        case .installedDirectoryUnavailable: return "Mary could not open its installed Abilities directory."
        case .rollbackFailed: return "Mary rejected the package but could not restore the previous installed file."
        }
    }
}

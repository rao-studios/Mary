//
//  AbilityLibrary+PackageOperations.swift
//

import ApplicationServices
import MaryFoundation
import CryptoKit
import Darwin
import Foundation
import os

extension AbilityLibrary {

    public func validate(json: String) -> AbilityPackageValidation {
        transactionLock.lock(); defer { transactionLock.unlock() }
        guard let data = json.data(using: .utf8),
              let package = try? AbilityPackageCodec.decode(data, verifyIntegrity: false)
        else {
            return AbilityPackageValidation(issues: [.init(
                severity: .error,
                code: "invalid-json",
                path: "$",
                message: "The document is not a decodable Mary ability package.")])
        }
        return validateForActivation(package)
    }

    /// Validate, normalize, atomically save, and activate. `expectedDigest`
    /// protects direct callers from silently overwriting an external edit;
    /// Ability Studio uses the stronger two-file edit-session contract below.
    @discardableResult
    public func save(
        json: String,
        expectedDigest: String? = nil
    ) throws -> AbilityLibraryReloadReport {
        transactionLock.lock(); defer { transactionLock.unlock() }
        guard let data = json.data(using: .utf8) else {
            throw AbilityLibraryError.invalidPackage([.init(
                severity: .error, code: "invalid-utf8", path: "$",
                message: "The package text is not UTF-8.")])
        }
        let package: MaryAbilityPackage
        do {
            package = try AbilityPackageCodec.decode(data, verifyIntegrity: false)
        } catch {
            throw AbilityLibraryError.invalidPackage([.init(
                severity: .error, code: "decode", path: "$",
                message: error.localizedDescription)])
        }
        let validation = validateForActivation(package)
        guard validation.isValid else { throw AbilityLibraryError.invalidPackage(validation.issues) }
        if package.integrity?.isSigned == true { throw AbilityLibraryError.packageIsSigned }

        guard let installed = installedDirectory() else {
            throw AbilityLibraryError.installedDirectoryUnavailable
        }
        try fileManager.createDirectory(at: installed, withIntermediateDirectories: true)
        let destination = installed.appendingPathComponent(package.package.id.rawValue)
            .appendingPathExtension("mary")
        return try installAndActivate(
            try AbilityPackageCodec.encoded(package),
            at: destination,
            expectedFileState: expectedDigest.map(ExpectedFileState.packageDigest) ?? .unchecked)
    }

    /// Everything the import review sheet must show before any byte lands on
    /// disk. Dynamic packages are data-only, so there is no executable-content
    /// approval path.
    public struct AbilityImportReview: Sendable {
        public var package: MaryAbilityPackage
        public var applicationTitle: String?
        public var bundleIdentifiers: [String]
        public var isSigned: Bool
    }

    public func previewImport(from sourceURL: URL) throws -> AbilityImportReview {
        transactionLock.lock(); defer { transactionLock.unlock() }
        let package = try AbilityPackageCodec.load(from: sourceURL)
        let validation = validateForActivation(package)
        guard validation.isValid else { throw AbilityLibraryError.invalidPackage(validation.issues) }
        let plugin = package.plugin
        return AbilityImportReview(
            package: package,
            applicationTitle: plugin?.application.title,
            bundleIdentifiers: plugin?.application.bundleIdentifiers ?? [],
            isSigned: package.integrity?.isSigned == true)
    }

    @discardableResult
    public func importPackage(from sourceURL: URL) throws -> AbilityLibraryReloadReport {
        transactionLock.lock(); defer { transactionLock.unlock() }
        let package = try AbilityPackageCodec.load(from: sourceURL)
        let validation = validateForActivation(package)
        guard validation.isValid else { throw AbilityLibraryError.invalidPackage(validation.issues) }
        guard let installed = installedDirectory() else {
            throw AbilityLibraryError.installedDirectoryUnavailable
        }
        try fileManager.createDirectory(at: installed, withIntermediateDirectories: true)
        let destination = installed.appendingPathComponent(package.package.id.rawValue)
            .appendingPathExtension("mary")
        // Import is additive. It may shadow an immutable bundled/source
        // definition, but it never replaces either an imported package or a
        // Studio override. The directory scan catches local packages whose
        // filename differs from their schema id as well as the canonical path.
        guard !hasLocalPackage(
            id: package.package.id,
            installedDirectory: installed)
        else { throw AbilityLibraryError.packageAlreadyInstalled(package.package.id) }
        let bytes = package.integrity?.isSigned == true
            ? try AbilityPackageCodec.contents(of: sourceURL)
            : try AbilityPackageCodec.encoded(package)
        return try installAndActivate(
            bytes,
            at: destination,
            expectedFileState: .missing,
            requiredActivePackage: .init(
                id: package.package.id,
                sourceURL: destination,
                fileSHA256: Self.fileSHA256(bytes)))
    }

    /// Studio's New Package door: a scaffolded, never-before-installed
    /// package minted straight into the installed directory. Same collision
    /// and atomic-activation rules as an import; unlike an import, the
    /// package was authored HERE, so nothing about it is unreviewed.
    @discardableResult
    public func createPackage(_ package: MaryAbilityPackage) throws -> AbilityLibraryReloadReport {
        transactionLock.lock(); defer { transactionLock.unlock() }
        let validation = validateForActivation(package)
        guard validation.isValid else { throw AbilityLibraryError.invalidPackage(validation.issues) }
        if package.integrity?.isSigned == true { throw AbilityLibraryError.packageIsSigned }
        guard let installed = installedDirectory() else {
            throw AbilityLibraryError.installedDirectoryUnavailable
        }
        try fileManager.createDirectory(at: installed, withIntermediateDirectories: true)
        let destination = installed.appendingPathComponent(package.package.id.rawValue)
            .appendingPathExtension("mary")
        guard !hasLocalPackage(
            id: package.package.id,
            installedDirectory: installed)
        else { throw AbilityLibraryError.packageAlreadyInstalled(package.package.id) }
        let bytes = try AbilityPackageCodec.encoded(package)
        return try installAndActivate(
            bytes,
            at: destination,
            expectedFileState: .missing,
            requiredActivePackage: .init(
                id: package.package.id,
                sourceURL: destination,
                fileSHA256: Self.fileSHA256(bytes)))
    }

    /// Begins authoring a package without installing it. The returned lease
    /// owns canonical JSON in memory and targets a destination proven absent;
    /// the first Save performs the atomic write and graph activation.
    public func beginCreatingPackage(
        _ package: MaryAbilityPackage
    ) throws -> AbilityPackageEditSession {
        transactionLock.lock(); defer { transactionLock.unlock() }
        let validation = validateForActivation(package)
        guard validation.isValid else {
            throw AbilityLibraryError.invalidPackage(validation.issues)
        }
        if package.integrity?.isSigned == true {
            throw AbilityLibraryError.packageIsSigned
        }
        guard let installed = installedDirectory() else {
            throw AbilityLibraryError.installedDirectoryUnavailable
        }
        guard snapshot().package(id: package.package.id) == nil,
              !hasLocalPackage(id: package.package.id, installedDirectory: installed)
        else { throw AbilityLibraryError.packageAlreadyInstalled(package.package.id) }

        let destination = installed
            .appendingPathComponent(package.package.id.rawValue)
            .appendingPathExtension("mary")
        let draftData = try AbilityPackageCodec.encoded(package)
        guard let draftJSON = String(data: draftData, encoding: .utf8) else {
            throw AbilityLibraryError.invalidPackage([])
        }
        return AbilityPackageEditSession(
            packageID: package.package.id,
            draftJSON: draftJSON,
            createsLocalOverride: false,
            createsNewPackage: true,
            sourceURL: nil,
            sourceFileSHA256: nil,
            destinationURL: destination,
            destinationFileSHA256: nil)
    }

    public func exportPackage(id: PackageID, to destination: URL) throws {
        transactionLock.lock(); defer { transactionLock.unlock() }
        guard let record = snapshot().package(id: id) else {
            throw AbilityLibraryError.packageNotFound
        }
        let output = destination.pathExtension.lowercased() == "mary"
            ? destination
            : destination.appendingPathExtension("mary")
        try record.rawData.write(to: output, options: .atomic)
    }

    /// Exports the document visible in Ability Studio, including unsaved
    /// changes, rather than consulting a registry snapshot that may have
    /// advanced behind the pinned editor. The exported package is canonical
    /// JSON and must pass the same schema/graph validation as a save, but an
    /// export does not require the source-file lease to remain current because
    /// producing the requested copy does not mutate the editing source.
    public func exportEditedPackage(
        json: String,
        session: AbilityPackageEditSession,
        to destination: URL
    ) throws {
        transactionLock.lock(); defer { transactionLock.unlock() }
        guard let data = json.data(using: .utf8) else {
            throw AbilityLibraryError.invalidPackage([.init(
                severity: .error,
                code: "invalid-utf8",
                path: "$",
                message: "The package text is not UTF-8.")])
        }
        let package: MaryAbilityPackage
        do {
            package = try AbilityPackageCodec.decode(data, verifyIntegrity: false)
        } catch {
            throw AbilityLibraryError.invalidPackage([.init(
                severity: .error,
                code: "decode",
                path: "$",
                message: error.localizedDescription)])
        }
        guard package.package.id == session.packageID else {
            throw AbilityLibraryError.invalidPackage([.init(
                severity: .error,
                code: "edited-package-id",
                path: "package.id",
                message: "An edit cannot change the package id from \(session.packageID.rawValue).")])
        }
        let validation = validateForActivation(package)
        guard validation.isValid else {
            throw AbilityLibraryError.invalidPackage(validation.issues)
        }
        let output = destination.pathExtension.lowercased() == "mary"
            ? destination
            : destination.appendingPathExtension("mary")
        let normalizedOutput = output.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedSource = session.sourceURL?.standardizedFileURL
            .resolvingSymlinksInPath()
        let normalizedEditingDestination = session.destinationURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard normalizedSource.map({ normalizedOutput != $0 }) ?? true,
              normalizedOutput != normalizedEditingDestination
        else { throw AbilityLibraryError.exportWouldOverwriteEditedPackage }
        try AbilityPackageCodec.encoded(package).write(to: output, options: .atomic)
    }

    /// Opens any active Ability as an editable document. Packages Mary must
    /// treat as immutable are represented by local drafts whose save
    /// destination is `Application Support/Mary/Abilities/Overrides`.
    /// If that override appeared since the last registry activation, Studio
    /// opens its exact verified bytes instead of silently replacing it with a
    /// draft derived from the stale active base. Existing editable local
    /// packages continue to edit their own file.
    public func beginEditingPackage(id: PackageID) throws -> AbilityPackageEditSession {
        transactionLock.lock(); defer { transactionLock.unlock() }
        guard let record = snapshot().package(id: id) else {
            throw AbilityLibraryError.packageNotFound
        }
        // The lease is over the exact bounded bytes Studio opened, not the
        // package's canonical integrity digest. JSON whitespace and key order
        // are still external edits and must invalidate an optimistic save.
        let sourceFileSHA256 = Self.fileSHA256(record.rawData)
        guard try verifiedFileSHA256(
            at: record.sourceURL,
            packageID: id) == sourceFileSHA256
        else { throw AbilityLibraryError.externalModification }
        let destination: URL
        let draftData: Data
        let createsLocalOverride: Bool
        let destinationFileSHA256: Data?

        if record.isEditable {
            destination = record.sourceURL
            draftData = record.rawData
            createsLocalOverride = false
            destinationFileSHA256 = sourceFileSHA256
        } else {
            guard let installed = installedDirectory() else {
                throw AbilityLibraryError.installedDirectoryUnavailable
            }
            destination = Self.localOverrideDirectory(for: installed)
                .appendingPathComponent(id.rawValue)
                .appendingPathExtension("mary")
            createsLocalOverride = true
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try verifiedFileSnapshot(
                    at: destination,
                    packageID: id)
                draftData = existing.bytes
                destinationFileSHA256 = existing.sha256
            } else {
                var local = record.package
                // Editing never mutates signed base bytes. A newly authored
                // override has its own digest and explicitly stops claiming
                // its publisher's signature or identity.
                local.integrity = nil
                local.package.publisher = "local"
                draftData = try AbilityPackageCodec.encoded(local)
                destinationFileSHA256 = nil
            }
        }
        guard let draftJSON = String(data: draftData, encoding: .utf8) else {
            throw AbilityLibraryError.invalidPackage([])
        }
        return AbilityPackageEditSession(
            packageID: id,
            draftJSON: draftJSON,
            createsLocalOverride: createsLocalOverride,
            createsNewPackage: false,
            sourceURL: record.sourceURL,
            sourceFileSHA256: sourceFileSHA256,
            destinationURL: destination,
            destinationFileSHA256: destinationFileSHA256)
    }

    /// Saves a Studio edit without weakening package provenance. Signed and
    /// bundled sources stay byte-for-byte intact underneath the local
    /// override. A concurrently changed source, override, or directly edited
    /// local package is rejected instead of being silently overwritten.
    @discardableResult
    public func saveEditedPackage(
        json: String,
        session: AbilityPackageEditSession
    ) throws -> AbilityLibraryReloadReport {
        transactionLock.lock(); defer { transactionLock.unlock() }
        guard let data = json.data(using: .utf8) else {
            throw AbilityLibraryError.invalidPackage([.init(
                severity: .error, code: "invalid-utf8", path: "$",
                message: "The package text is not UTF-8.")])
        }
        let package: MaryAbilityPackage
        do {
            package = try AbilityPackageCodec.decode(data, verifyIntegrity: false)
        } catch {
            throw AbilityLibraryError.invalidPackage([.init(
                severity: .error, code: "decode", path: "$",
                message: error.localizedDescription)])
        }
        guard package.package.id == session.packageID else {
            throw AbilityLibraryError.invalidPackage([.init(
                severity: .error,
                code: "edited-package-id",
                path: "package.id",
                message: "An edit cannot change the package id from \(session.packageID.rawValue).")])
        }
        let validation = validateForActivation(package)
        guard validation.isValid else {
            throw AbilityLibraryError.invalidPackage(validation.issues)
        }
        if package.integrity?.isSigned == true {
            throw AbilityLibraryError.packageIsSigned
        }

        // When an immutable source is being overlaid, also guard the source
        // itself. This closes the race where the repository or imported
        // signed package changes after Studio opened but before the first save.
        if let sourceURL = session.sourceURL,
           let sourceFileSHA256 = session.sourceFileSHA256,
           sourceURL.standardizedFileURL
            != session.destinationURL.standardizedFileURL {
            guard (try? verifiedFileSHA256(
                at: sourceURL,
                packageID: session.packageID)) == sourceFileSHA256
            else { throw AbilityLibraryError.externalModification }
        }

        // A new-package lease is optimistic over the package identity, not
        // only its canonical destination filename. Recheck both writable
        // layers at commit so another local package cannot be shadowed.
        if session.createsNewPackage {
            guard let installed = installedDirectory() else {
                throw AbilityLibraryError.installedDirectoryUnavailable
            }
            guard snapshot().package(id: session.packageID) == nil,
                  !hasLocalPackage(id: session.packageID, installedDirectory: installed)
            else { throw AbilityLibraryError.packageAlreadyInstalled(session.packageID) }
        }
        try fileManager.createDirectory(
            at: session.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let state: ExpectedFileState = session.destinationFileSHA256
            .map { .fileSHA256($0, packageID: session.packageID) } ?? .missing
        return try installAndActivate(
            try AbilityPackageCodec.encoded(package),
            at: session.destinationURL,
            expectedFileState: state)
    }

    public func rawJSON(id: PackageID) throws -> String {
        transactionLock.lock(); defer { transactionLock.unlock() }
        guard let record = snapshot().package(id: id),
              let text = String(data: record.rawData, encoding: .utf8)
        else { throw AbilityLibraryError.packageNotFound }
        return text
    }
}

//
//  AbilityLibrary+Activation.swift
//  MaryBrain
//
//  WHAT: Activate / deactivate admitted packages.
//  IN:   AbilityLibrary.swift
//  OUT:  immutable snapshot replacement
//
import ApplicationServices
import MaryFoundation
import CryptoKit
import Darwin
import Foundation
import os

extension AbilityLibrary {

    /// Commits a candidate file only if the complete installed package graph activates.
    enum ExpectedFileState {
        case unchecked
        case missing
        /// Compatibility seam for direct callers of `save(json:expectedDigest:)`.
        case packageDigest(String)
        /// Ability Studio's byte-exact optimistic editing lease.
        case fileSHA256(Data, packageID: PackageID)
    }

    struct RequiredActivePackage {
        var id: PackageID
        var sourceURL: URL
        var fileSHA256: Data
    }

    func installAndActivate(
        _ data: Data,
        at destination: URL,
        expectedFileState: ExpectedFileState = .unchecked,
        requiredActivePackage: RequiredActivePackage? = nil
    ) throws -> AbilityLibraryReloadReport {
        let existed = fileManager.fileExists(atPath: destination.path)
        let previous = existed ? try AbilityPackageCodec.contents(of: destination) : nil
        switch expectedFileState {
        case .unchecked:
            break
        case .missing:
            guard previous == nil else {
                throw AbilityLibraryError.externalModification
            }
        case .packageDigest(let expectedDigest):
            guard let previous,
                  let existing = try? AbilityPackageCodec.decode(previous),
                  (try? Self.packageDigest(existing)) == expectedDigest
            else { throw AbilityLibraryError.externalModification }
        case .fileSHA256(let expectedSHA256, let packageID):
            guard let previous,
                  (try? Self.verifyIdentityAndIntegrity(
                    of: previous,
                    packageID: packageID)) != nil,
                  Self.fileSHA256(previous) == expectedSHA256
            else { throw AbilityLibraryError.externalModification }
        }
        try data.write(to: destination, options: .atomic)
        let report = reload()
        let requiredPackageIsActive: Bool
        if let requiredActivePackage,
           let active = report.snapshot.package(id: requiredActivePackage.id) {
            requiredPackageIsActive = active.sourceURL.standardizedFileURL
                == requiredActivePackage.sourceURL.standardizedFileURL
                && Self.fileSHA256(active.rawData) == requiredActivePackage.fileSHA256
        } else {
            requiredPackageIsActive = requiredActivePackage == nil
        }
        if report.activated, requiredPackageIsActive { return report }

        do {
            if let previous {
                try previous.write(to: destination, options: .atomic)
            } else if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            _ = reload()
        } catch {
            throw AbilityLibraryError.rollbackFailed
        }
        if let requiredActivePackage, report.activated {
            throw AbilityLibraryError.packageAlreadyInstalled(requiredActivePackage.id)
        }
        throw AbilityLibraryError.invalidPackage(report.issues)
    }

    /// Validates the graph that would exist after installing `candidate`.
    func validateForActivation(
        _ candidate: MaryAbilityPackage
    ) -> AbilityPackageValidation {
        let packages = snapshot().records
            .map(\.package)
            .filter { $0.package.id != candidate.package.id }
            + [candidate]
        var issues = AbilityPackageValidator.validateGraph(packages).issues
        let configuration: (
            manifests: [InstalledAdapterManifest],
            nativeApplicationProfiles: [ApplicationProfile],
            reservedManifests: [InstalledAdapterManifest],
            reservedNativeApplicationProfiles: [ApplicationProfile],
            primitives: [LocalSkillBinding]
        ) = {
            lock.lock(); defer { lock.unlock() }
            return (
                state.adapterManifests,
                state.nativeApplicationProfiles,
                state.reservedNativeAdapterManifests,
                state.reservedNativeApplicationProfiles,
                state.primitiveBindings)
        }()
        let plugins = PluginCompiler.compile(
            packages: packages,
            nativeAdapterManifests: configuration.manifests,
            nativeApplicationProfiles: configuration.nativeApplicationProfiles,
            reservedNativeAdapterManifests: configuration.reservedManifests,
            reservedNativeApplicationProfiles: configuration.reservedNativeApplicationProfiles,
            grantedPermissions: packageGrantedPermissions)
        let known = Set(issues)
        issues.append(contentsOf: plugins.issues.filter { !known.contains($0) })
        let capabilitySchemas = Dictionary(
            packages.flatMap(\.capabilities).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        issues.append(contentsOf: InstalledAdapterInventory.validationIssues(
            manifests: configuration.manifests + plugins.adapterManifests,
            primitiveBindings: configuration.primitives,
            capabilitySchemas: capabilitySchemas))
        if let minimum = candidate.package.minimumMaryVersion,
           runtimeVersion < minimum {
            issues.append(.init(
                severity: .error,
                code: "minimum-mary-version",
                path: "package.minimumMaryVersion",
                message: "Package \(candidate.package.id.rawValue) requires Mary \(minimum.rawValue) or newer; this runtime is \(runtimeVersion.rawValue)."))
        }
        return AbilityPackageValidation(issues: issues)
    }

    struct VerifiedFileSnapshot {
        var bytes: Data
        var sha256: Data
    }

    /// Reads through the package-size boundary, verifies schema identity and declared integrity independently, then retains and hashes the same exact bytes.
    func verifiedFileSnapshot(
        at url: URL,
        packageID: PackageID
    ) throws -> VerifiedFileSnapshot {
        let bytes = try AbilityPackageCodec.contents(of: url)
        try Self.verifyIdentityAndIntegrity(of: bytes, packageID: packageID)
        return VerifiedFileSnapshot(bytes: bytes, sha256: Self.fileSHA256(bytes))
    }

    func verifiedFileSHA256(at url: URL, packageID: PackageID) throws -> Data {
        try verifiedFileSnapshot(at: url, packageID: packageID).sha256
    }

    static func verifyIdentityAndIntegrity(
        of bytes: Data,
        packageID: PackageID
    ) throws {
        let package = try AbilityPackageCodec.decode(bytes)
        guard package.package.id == packageID else {
            throw AbilityLibraryError.externalModification
        }
    }

    static func fileSHA256(_ bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }

    static func packageDigest(_ package: MaryAbilityPackage) throws -> String {
        if let digest = package.integrity?.digest { return digest }
        return try AbilityPackageCodec.digest(of: package)
    }

    func hasLocalPackage(
        id: PackageID,
        installedDirectory: URL
    ) -> Bool {
        let directories = [
            installedDirectory,
            Self.localOverrideDirectory(for: installedDirectory),
        ]
        for directory in directories {
            let canonical = directory.appendingPathComponent(id.rawValue)
                .appendingPathExtension("mary")
            if fileManager.fileExists(atPath: canonical.path) { return true }
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for file in files where file.pathExtension.lowercased() == "mary" {
                if (try? AbilityPackageCodec.load(from: file).package.id) == id {
                    return true
                }
            }
        }
        return false
    }

}

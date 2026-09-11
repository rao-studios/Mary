//
//  AbilityLibrary+PackageLifecycle.swift
//  MaryBrain
//
//  WHAT: Import / remove / validate package lifecycle.
//  IN:   AbilityLibrary.swift
//  OUT:  last-known-good snapshot stays put on a bad edit
//
import ApplicationServices
import MaryFoundation
import CryptoKit
import Darwin
import Foundation
import os

extension AbilityLibrary {

    /// Called at boot after plugins have declared the operations available on
    /// this machine, and again when plugin settings change.
    @discardableResult
    public func configureAndLoad(
        adapterManifests: [InstalledAdapterManifest],
        nativeApplicationProfiles: [ApplicationProfile] = [],
        reservedNativeAdapterManifests: [InstalledAdapterManifest]? = nil,
        reservedNativeApplicationProfiles: [ApplicationProfile]? = nil,
        primitiveBindings: [LocalSkillBinding] = [],
        locations suppliedLocations: [AbilityPackageLocation]? = nil,
        installedDirectory suppliedInstalledDirectory: URL? = nil
    ) -> AbilityLibraryReloadReport {
        _ = Self.installAmbientIndex
        transactionLock.lock(); defer { transactionLock.unlock() }
        let inventoryIssues = InstalledAdapterInventory.validationIssues(
            manifests: adapterManifests,
            primitiveBindings: primitiveBindings)
        guard !inventoryIssues.contains(where: { $0.severity == .error }) else {
            let current = snapshot()
            lock.lock()
            state.lastIssues = inventoryIssues
            let continuations = Array(state.continuations.values)
            lock.unlock()
            continuations.forEach { $0.yield(.rejected(inventoryIssues)) }
            log.error("adapter inventory rejected with \(inventoryIssues.count, privacy: .public) issue(s)")
            return AbilityLibraryReloadReport(
                activated: false,
                snapshot: current,
                issues: inventoryIssues,
                filesRead: 0)
        }
        let installed = suppliedInstalledDirectory ?? Self.defaultInstalledDirectory(fileManager: fileManager)
        var locations = suppliedLocations ?? Self.defaultLocations(installedDirectory: installed)
        // Tests and embedders can provide their own discovery roots. When they
        // also provide the writable root, preserve the same two-layer contract
        // as the app: imports below, Studio overrides above.
        if suppliedLocations != nil, let suppliedInstalledDirectory {
            if !locations.contains(where: {
                $0.directory.standardizedFileURL
                    == suppliedInstalledDirectory.standardizedFileURL
            }) {
                locations.append(.init(
                    directory: suppliedInstalledDirectory,
                    source: .installed,
                    priority: (locations.map(\.priority).max() ?? 90) + 10))
            }
            let override = Self.localOverrideDirectory(for: suppliedInstalledDirectory)
            if !locations.contains(where: {
                $0.directory.standardizedFileURL == override.standardizedFileURL
            }) {
                locations.append(.init(
                    directory: override,
                    source: .installed,
                    priority: (locations.map(\.priority).max() ?? 100) + 10))
            }
        }
        // The two writable roots are part of the runtime contract.
        if let installed {
            try? fileManager.createDirectory(
                at: installed,
                withIntermediateDirectories: true)
            try? fileManager.createDirectory(
                at: Self.localOverrideDirectory(for: installed),
                withIntermediateDirectories: true)
        }
        let priorConfiguration: (
            adapterManifests: [InstalledAdapterManifest],
            nativeApplicationProfiles: [ApplicationProfile],
            reservedNativeAdapterManifests: [InstalledAdapterManifest],
            reservedNativeApplicationProfiles: [ApplicationProfile],
            primitiveBindings: [LocalSkillBinding],
            locations: [AbilityPackageLocation],
            installedDirectory: URL?,
            configured: Bool,
            filesystemFingerprint: Data?
        ) = {
            lock.lock(); defer { lock.unlock() }
            return (
                state.adapterManifests,
                state.nativeApplicationProfiles,
                state.reservedNativeAdapterManifests,
                state.reservedNativeApplicationProfiles,
                state.primitiveBindings,
                state.locations,
                state.installedDirectory,
                state.configured,
                state.filesystemFingerprint)
        }()
        lock.lock()
        state.adapterManifests = adapterManifests
        state.nativeApplicationProfiles = nativeApplicationProfiles
        state.reservedNativeAdapterManifests = reservedNativeAdapterManifests
            ?? adapterManifests
        state.reservedNativeApplicationProfiles = reservedNativeApplicationProfiles
            ?? nativeApplicationProfiles
        state.primitiveBindings = primitiveBindings
        state.locations = locations
        state.installedDirectory = installed
        state.configured = true
        lock.unlock()
        let report = reload()
        guard !report.activated, priorConfiguration.configured else {
            // The first configuration has no previous discovery roots or inventory to restore.
            return report
        }

        // Configuration and its compiled snapshot are one transaction.
        lock.lock()
        state.adapterManifests = priorConfiguration.adapterManifests
        state.nativeApplicationProfiles = priorConfiguration.nativeApplicationProfiles
        state.reservedNativeAdapterManifests = priorConfiguration.reservedNativeAdapterManifests
        state.reservedNativeApplicationProfiles = priorConfiguration.reservedNativeApplicationProfiles
        state.primitiveBindings = priorConfiguration.primitiveBindings
        state.locations = priorConfiguration.locations
        state.installedDirectory = priorConfiguration.installedDirectory
        state.configured = priorConfiguration.configured
        state.filesystemFingerprint = priorConfiguration.filesystemFingerprint
        lock.unlock()
        refreshFilesystemObservation(for: priorConfiguration.locations)
        return report
    }

    /// Publishes or replaces one adapter's current handshake, then activates a new immutable registry revision.
    @discardableResult
    public func publishAdapterManifest(
        _ manifest: InstalledAdapterManifest
    ) -> AbilityLibraryReloadReport {
        transactionLock.lock(); defer { transactionLock.unlock() }
        let defaultInstalled = Self.defaultInstalledDirectory(fileManager: fileManager)
        let defaultLocations = Self.defaultLocations(installedDirectory: defaultInstalled)
        lock.lock()
        var manifests = state.adapterManifests.filter { $0.adapterID != manifest.adapterID }
        manifests.append(manifest)
        let inventoryIssues = InstalledAdapterInventory.validationIssues(
            manifests: manifests,
            primitiveBindings: state.primitiveBindings)
        guard !inventoryIssues.contains(where: { $0.severity == .error }) else {
            let current = state.snapshot
            state.lastIssues = inventoryIssues
            let continuations = Array(state.continuations.values)
            lock.unlock()
            continuations.forEach { $0.yield(.rejected(inventoryIssues)) }
            log.error("adapter manifest rejected with \(inventoryIssues.count, privacy: .public) issue(s)")
            return AbilityLibraryReloadReport(
                activated: false,
                snapshot: current,
                issues: inventoryIssues,
                filesRead: 0)
        }
        state.adapterManifests = manifests
        if let reservedIndex = state.reservedNativeAdapterManifests.firstIndex(where: {
            $0.adapterID == manifest.adapterID
        }) {
            var reserved = state.reservedNativeAdapterManifests[reservedIndex]
            let reservedOperations = Set(reserved.operations.map(\.operation))
            reserved.operations.append(contentsOf: manifest.operations.filter {
                !reservedOperations.contains($0.operation)
            })
            reserved.providesInteractions = Array(
                Set(reserved.providesInteractions).union(manifest.providesInteractions))
            reserved.providesPerceptions = Array(
                Set(reserved.providesPerceptions).union(manifest.providesPerceptions))
            state.reservedNativeAdapterManifests[reservedIndex] = reserved
        } else {
            state.reservedNativeAdapterManifests.append(manifest)
        }
        if !state.configured {
            state.locations = defaultLocations
            state.installedDirectory = defaultInstalled
            state.configured = true
        }
        lock.unlock()
        return reload()
    }

    @discardableResult
    public func reload() -> AbilityLibraryReloadReport {
        transactionLock.lock(); defer { transactionLock.unlock() }
        let configuration: (
            locations: [AbilityPackageLocation],
            adapterManifests: [InstalledAdapterManifest],
            nativeApplicationProfiles: [ApplicationProfile],
            reservedNativeAdapterManifests: [InstalledAdapterManifest],
            reservedNativeApplicationProfiles: [ApplicationProfile],
            primitiveBindings: [LocalSkillBinding]
        ) = {
            lock.lock(); defer { lock.unlock() }
            return (
                state.locations,
                state.adapterManifests,
                state.nativeApplicationProfiles,
                state.reservedNativeAdapterManifests,
                state.reservedNativeApplicationProfiles,
                state.primitiveBindings)
        }()
        // Capture the pre-discovery bytes. If an external writer races the discovery pass
        let filesystemFingerprint = fingerprint(of: configuration.locations)
        let discovery = discover(in: configuration.locations)
        let graph = AbilityPackageValidator.validateGraph(discovery.records.map(\.package))
        let compatibilityIssues = discovery.records.compactMap { record -> SchemaIssue? in
            guard let minimum = record.package.package.minimumMaryVersion,
                  runtimeVersion < minimum
            else { return nil }
            return SchemaIssue(
                severity: .error,
                code: "minimum-mary-version",
                path: record.sourceURL.path,
                message: "Package \(record.id.rawValue) requires Mary \(minimum.rawValue) or newer; this runtime is \(runtimeVersion.rawValue).")
        }
        let capabilitySchemas = Dictionary(
            discovery.records.flatMap { $0.package.capabilities }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let plugins = PluginCompiler.compile(
            packages: discovery.records.map(\.package),
            nativeAdapterManifests: configuration.adapterManifests,
            nativeApplicationProfiles: configuration.nativeApplicationProfiles,
            reservedNativeAdapterManifests: configuration.reservedNativeAdapterManifests,
            reservedNativeApplicationProfiles: configuration.reservedNativeApplicationProfiles,
            packageSources: Dictionary(
                discovery.records.map { ($0.id, $0.source) },
                uniquingKeysWith: { first, _ in first }),
            grantedPermissions: packageGrantedPermissions)
        let inventoryIssues = InstalledAdapterInventory.validationIssues(
            manifests: configuration.adapterManifests + plugins.adapterManifests,
            primitiveBindings: configuration.primitiveBindings,
            capabilitySchemas: capabilitySchemas)
        let priorIssues = discovery.issues + graph.issues + compatibilityIssues
        let priorIssueSet = Set(priorIssues)
        let compilationIssues = plugins.issues.filter {
            !priorIssueSet.contains($0)
        }
        let issues = priorIssues + compilationIssues + inventoryIssues
        guard !issues.contains(where: { $0.severity == .error }) else {
            let current = snapshot()
            lock.lock()
            state.lastIssues = issues
            state.filesystemFingerprint = filesystemFingerprint
            let continuations = Array(state.continuations.values)
            lock.unlock()
            refreshFilesystemObservation(for: configuration.locations)
            continuations.forEach { $0.yield(.rejected(issues)) }
            log.error("ability reload rejected with \(issues.count, privacy: .public) issue(s)")
            return AbilityLibraryReloadReport(
                activated: false,
                snapshot: current,
                issues: issues,
                filesRead: discovery.filesRead)
        }
        // WHAT `{application}` MEANS, decided once for every corpus below.
        // Three of these builders read `fixture.utterance` straight into a
        // vectorizer; if each learned the pragma separately, the one that
        // forgot would embed a literal "{application}" — a term nobody says.
        let templates = UtteranceTemplateExpander(records: discovery.records)
        let next = AbilityRuntime.Snapshot(
            records: discovery.records,
            validation: AbilityPackageValidation(issues: issues),
            adapterManifests: configuration.adapterManifests,
            primitiveBindings: configuration.primitiveBindings,
            plugins: plugins,
            // Built here — at reload, off the turn path — so the embedding
            // model load and corpus vectorization never cost a turn a
            // millisecond. THE ENGINE IS `MaryEmbeddings`' CHOICE, not this
            // file's: no vectorizer at all still means nil, exact-only.
            semanticIndex: MaryEmbeddings.vectorizer().flatMap {
                SemanticAbilityRequestIndex.build(
                    records: discovery.records, vectorizer: $0, templates: templates)
            },
            // The Skill tier is built in the same breath and for the same
            // reason: one model load, two corpora, both off the turn path.
            semanticSkillIndex: MaryEmbeddings.vectorizer().flatMap {
                SemanticSkillRequestIndex.build(
                    records: discovery.records, vectorizer: $0, templates: templates)
            },
            // The intent tier reads every installed package's own
            // `intentSeeds` — a third corpus, same one model load.
            semanticIntentIndex: MaryEmbeddings.vectorizer().flatMap {
                SemanticIntentIndex.build(
                    records: discovery.records, vectorizer: $0, templates: templates)
            },
            // The fourth corpus: named seed families, the shapes of speech
            // that are neither an intent nor a Skill. Same one model load.
            semanticSeedFamilyIndex: MaryEmbeddings.vectorizer().flatMap {
                SemanticSeedFamilyIndex.build(
                    records: discovery.records, vectorizer: $0)
            },
            // The fifth corpus: the applications a system-control Skill can be
            // pointed at, named the way people say them. Same one model load.
            semanticApplicationIndex: MaryEmbeddings.vectorizer().flatMap {
                SemanticApplicationIndex.build(
                    records: discovery.records, vectorizer: $0, templates: templates)
            },
            templates: templates)
        lock.lock()
        state.snapshot = next
        state.lastIssues = issues
        state.filesystemFingerprint = filesystemFingerprint
        let continuations = Array(state.continuations.values)
        lock.unlock()
        refreshFilesystemObservation(for: configuration.locations)
        continuations.forEach { $0.yield(.activated(next)) }
        log.info("activated ability registry \(next.revision.uuidString, privacy: .public) with \(next.records.count, privacy: .public) package(s)")
        return AbilityLibraryReloadReport(
            activated: true,
            snapshot: next,
            issues: issues,
            filesRead: discovery.filesRead)
    }

}

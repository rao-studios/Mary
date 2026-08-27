import ApplicationServices
import MaryFoundation
import CryptoKit
import Darwin
import Foundation
import os

/// Loads root/bundled `.mary` definitions plus a writable Application
/// Support overlay. Candidate graphs validate completely before one immutable
/// snapshot replaces another; a bad edit never disturbs the last-known-good
/// runtime.
public final class AbilityLibrary: @unchecked Sendable {
    /// The installed Ability graph is the activation boundary for a Dynamic
    /// Plugin. Native Plugin Settings never participate here. The production
    /// library reflects the process's live macOS grant for the one permission
    /// the closed `macUI` interpreter can currently use; execution rechecks
    /// that grant immediately before touching the target application.
    ///
    /// Individually constructed libraries retain the fail-closed resolver
    /// default below so tests, tools, and future hosts must opt into machine
    /// authority explicitly.
    public static let shared = AbilityLibrary(packageGrantedPermissions: { request in
        var granted: Set<PermissionKind> = []
        if request.requestedPermissions.contains(.accessibility), AXIsProcessTrusted() {
            granted.insert(.accessibility)
        }
        return granted
    })

    struct State {
        var snapshot: AbilityRuntimeSnapshot = .empty
        var locations: [AbilityPackageLocation] = []
        var installedDirectory: URL?
        var adapterManifests: [InstalledAdapterManifest] = []
        var nativeApplicationProfiles: [ApplicationProfile] = []
        var reservedNativeAdapterManifests: [InstalledAdapterManifest] = []
        var reservedNativeApplicationProfiles: [ApplicationProfile] = []
        var primitiveBindings: [LocalSkillBinding] = []
        var continuations: [UUID: AsyncStream<AbilityLibraryEvent>.Continuation] = [:]
        var lastIssues: [SchemaIssue] = []
        var filesystemFingerprint: Data?
        var configured = false
    }

    /// A directory descriptor is intentionally retained for the lifetime of
    /// its dispatch source. Directory events are only a wake-up signal; the
    /// library still proves an exact content fingerprint before reloading.
    final class DirectoryObservation {
        let source: DispatchSourceFileSystemObject

        init?(
            url: URL,
            queue: DispatchQueue,
            changed: @escaping @Sendable () -> Void
        ) {
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke],
                queue: queue)
            source.setEventHandler(handler: changed)
            source.setCancelHandler { close(descriptor) }
            source.resume()
        }

        deinit { source.cancel() }
    }

    let lock = NSLock()
    /// Serializes configuration, package-file transactions, validation, and
    /// activation as one operation. It is recursive because save/import call
    /// the public reload seam after atomically replacing a candidate file.
    let transactionLock = NSRecursiveLock()
    var state = State()
    let fileManager: FileManager
    let runtimeVersion: SemanticVersion
    let packageGrantedPermissions: PluginCompiler.GrantedPermissionResolver
    let log = Logger(subsystem: "nyc.rao.mary", category: "abilities")
    let observationQueue = DispatchQueue(
        label: "nyc.rao.mary.ability-library.filesystem",
        qos: .utility)
    let observationQueueKey = DispatchSpecificKey<UInt8>()
    var directoryObservations: [String: DirectoryObservation] = [:]
    var observedReloadWorkItem: DispatchWorkItem?

    public init(
        fileManager: FileManager = .default,
        runtimeVersion: SemanticVersion = AbilityLibrary.detectedRuntimeVersion,
        // A standalone library is inert until its host injects machine truth.
        // Mary's process singleton above treats successful Ability
        // installation as provider activation and supplies the live OS grant;
        // this default keeps other hosts and tests fail-closed.
        packageGrantedPermissions: @escaping PluginCompiler.GrantedPermissionResolver = { _ in [] }
    ) {
        self.fileManager = fileManager
        self.runtimeVersion = runtimeVersion
        self.packageGrantedPermissions = packageGrantedPermissions
        observationQueue.setSpecific(key: observationQueueKey, value: 1)
    }

    deinit {
        performOnObservationQueue {
            self.observedReloadWorkItem?.cancel()
            self.observedReloadWorkItem = nil
            self.directoryObservations.removeAll()
        }
    }

    public func snapshot() -> AbilityRuntimeSnapshot {
        if let turn = AbilityTurnContext.snapshot { return turn }
        lock.lock(); defer { lock.unlock() }
        return state.snapshot
    }

    /// Returns the active registry, loading package definitions on first use.
    /// The app normally configures concrete adapter bindings during boot; this
    /// lazy path keeps schema-driven routing honest in package tests, probes,
    /// and other callers that resolve a route before the app runtime exists.
    public func snapshotEnsuringLoaded() -> AbilityRuntimeSnapshot {
        lock.lock()
        let isConfigured = state.configured
        let current = state.snapshot
        lock.unlock()
        if isConfigured { return AbilityTurnContext.snapshot ?? current }
        return configureAndLoad(adapterManifests: []).snapshot
    }

    public func lastIssues() -> [SchemaIssue] {
        lock.lock(); defer { lock.unlock() }
        return state.lastIssues
    }

    public func installedDirectory() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return state.installedDirectory
    }

    public func events() -> AsyncStream<AbilityLibraryEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AbilityLibraryEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4))
        lock.lock()
        state.continuations[id] = continuation
        let current = state.snapshot
        lock.unlock()
        continuation.yield(.activated(current))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.state.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    /// Points MaryAmbient at this registry the first time one is loaded.
    ///
    /// Installed HERE rather than only at the app's composition root because a
    /// loaded registry is exactly the precondition the ambient layer's index
    /// describes — so every caller that has one, including a test, gets the
    /// live answer instead of an empty index.
    static let installAmbientIndex: Void = {
        AmbientCapabilityIndexProvider.install {
            AbilityLibrary.shared.snapshotEnsuringLoaded()
        }
    }()

    public static func defaultInstalledDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mary", isDirectory: true)
            .appendingPathComponent("Abilities", isDirectory: true)
    }

    public static func localOverrideDirectory(for installedDirectory: URL) -> URL {
        installedDirectory.appendingPathComponent("Overrides", isDirectory: true)
    }

    /// Package compatibility is evaluated at activation, before a new graph
    /// replaces the last-known-good snapshot. The app bundle supplies its
    /// marketing version; SwiftPM tools/tests use the schema runtime baseline.
    public static var detectedRuntimeVersion: SemanticVersion {
        if let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.isEmpty {
            return SemanticVersion(value)
        }
        return "1.0.0"
    }

    /// The checkout this source file lives in, found by WALKING UP UNTIL THE
    /// SHAPE MATCHES rather than by counting directories.
    ///
    /// THE FAILURE THIS PREVENTS: what stood here was
    /// `for _ in 0..<6 { deleteLastPathComponent() }`, six being however deep
    /// this file happened to sit. Moving it one directory — an ordinary tidy
    /// — would have pointed the source-tree location at
    /// `…/MaryBrain/Abilities`, which does not exist. Package loading would
    /// then silently fall back to whatever stale copy the app bundle carried,
    /// and the flagship plugin would go quietly wrong in a way that looks
    /// like a Sketch bug. A path derived from a hop count is a path that
    /// breaks when someone reorganizes files; this one cannot.
    ///
    /// Nil when no ancestor qualifies — a compiled binary running from an
    /// unrelated tree, where the bundled and installed locations are the
    /// honest answer anyway.
    static func repositoryRoot(from filePath: String) -> URL? {
        var candidate = URL(fileURLWithPath: filePath)
        // Bounded: deep enough for any checkout layout, finite on a
        // filesystem that answers oddly.
        for _ in 0..<12 {
            candidate.deleteLastPathComponent()
            guard candidate.path != "/" , !candidate.path.isEmpty else { return nil }
            if holdsAbilityPackages(candidate) { return candidate }
        }
        return nil
    }

    /// True when this directory has an `Abilities` folder holding at least one
    /// real `.mary` package.
    ///
    /// THE NAME ALONE IS NOT ENOUGH, and that is not hypothetical: the
    /// MaryBrain source tree has its own directory called `Abilities` (the
    /// one this file lives in), so a walk that stopped at the first folder
    /// with that name stopped four levels short — inside the package, not at
    /// the checkout. Asserting the CONTENT asks the question we actually mean.
    static func holdsAbilityPackages(_ directory: URL) -> Bool {
        let abilities = directory.appendingPathComponent("Abilities", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: abilities.path) else { return false }
        return entries.contains { $0.hasSuffix(".mary") }
    }

    public static func defaultLocations(
        installedDirectory: URL? = defaultInstalledDirectory()
    ) -> [AbilityPackageLocation] {
        var locations: [AbilityPackageLocation] = []
        if let resourceURL = Bundle.main.resourceURL {
            locations.append(.init(
                directory: resourceURL.appendingPathComponent("Abilities", isDirectory: true),
                source: .bundled,
                priority: 10))
        }
        if let override = ProcessInfo.processInfo.environment["MARY_ABILITIES_PATH"],
           !override.isEmpty {
            locations.append(.init(
                directory: URL(fileURLWithPath: override, isDirectory: true),
                source: .sourceTree,
                priority: 30))
        } else {
            if let repository = Self.repositoryRoot(from: #filePath) {
                locations.append(.init(
                    directory: repository.appendingPathComponent("Abilities", isDirectory: true),
                    source: .sourceTree,
                    priority: 20))
            }
            locations.append(.init(
                directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Abilities", isDirectory: true),
                source: .sourceTree,
                priority: 20))
        }
        if let installedDirectory {
            locations.append(.init(
                directory: installedDirectory,
                source: .installed,
                priority: 100))
            locations.append(.init(
                directory: localOverrideDirectory(for: installedDirectory),
                source: .installed,
                priority: 110))
        }
        // The source-tree candidate and cwd are commonly identical in tests.
        var seen: Set<String> = []
        return locations.filter { seen.insert($0.directory.standardizedFileURL.path).inserted }
    }
}

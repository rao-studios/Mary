import CryptoKit
import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

@Suite struct AbilityLibraryTests {
    @Test func installedPackageOverridesSourceDefinition() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundled = Self.package(id: "tests.portable", title: "Bundled")
        var installed = bundled
        installed.ability.title = "Local override"
        try fixture.write(bundled, named: "portable.mary", to: fixture.source)
        try fixture.write(installed, named: "portable.mary", to: fixture.installed)

        let library = AbilityLibrary(
            fileManager: .default,
            runtimeVersion: "1.0.0")
        let report = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
                .init(directory: fixture.installed, source: .installed, priority: 100),
            ],
            installedDirectory: fixture.installed)

        #expect(report.activated)
        #expect(report.snapshot.records.count == 1)
        #expect(report.snapshot.records.first?.source == .installed)
        #expect(report.snapshot.records.first?.package.ability.title == "Local override")
    }

    @Test func samePriorityPackageVersionsAreRejectedInsteadOfFilenameSelected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Self.package(id: "tests.ambiguous-version", title: "One")
        var second = first
        second.package.version = "2.0.0"
        second.ability.title = "Two"
        try fixture.write(first, named: "a.mary", to: fixture.source)
        try fixture.write(second, named: "z.mary", to: fixture.source)

        let library = AbilityLibrary(
            fileManager: .default,
            runtimeVersion: "1.0.0")
        let report = library.configureAndLoad(
            adapterManifests: [],
            locations: [.init(
                directory: fixture.source,
                source: .sourceTree,
                priority: 20)],
            installedDirectory: fixture.installed)

        #expect(!report.activated)
        #expect(report.issues.contains {
            $0.code == "duplicate-source-package"
                && $0.message.contains("1.0.0")
                && $0.message.contains("2.0.0")
        })
    }

    @Test func minimumRuntimeVersionRejectsCandidateAndKeepsLastKnownGood() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let library = AbilityLibrary(
            fileManager: .default,
            runtimeVersion: "1.0.0")
        try fixture.write(
            Self.package(id: "tests.baseline", title: "Baseline"),
            named: "baseline.mary",
            to: fixture.source)
        let first = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        #expect(first.activated)
        let baselineRevision = first.snapshot.revision

        var future = Self.package(
            id: "tests.future",
            title: "Future",
            invocation: "inspect_future")
        future.package.minimumMaryVersion = "9.0.0"
        try fixture.write(future, named: "future.mary", to: fixture.source)
        let rejected = library.reload()

        #expect(!rejected.activated)
        #expect(rejected.issues.contains { $0.code == "minimum-mary-version" })
        #expect(rejected.snapshot.revision == baselineRevision)
        #expect(library.snapshot().records.map(\.id) == [PackageID("tests.baseline")])
    }

    @Test func graphInvalidImportRollsBackFileAndSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Self.package(
            id: "tests.original",
            title: "Original",
            invocation: "shared_invocation")
        try fixture.write(original, named: "original.mary", to: fixture.source)
        let library = AbilityLibrary(
            fileManager: .default,
            runtimeVersion: "1.0.0")
        let first = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
                .init(directory: fixture.installed, source: .installed, priority: 100),
            ],
            installedDirectory: fixture.installed)
        #expect(first.activated)

        let conflicting = Self.package(
            id: "tests.conflicting",
            title: "Conflicting",
            invocation: "shared_invocation")
        let importURL = fixture.root.appendingPathComponent("conflicting.mary")
        try AbilityPackageCodec.encoded(conflicting).write(to: importURL)

        #expect(throws: AbilityLibraryError.self) {
            _ = try library.importPackage(from: importURL)
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.installed
                .appendingPathComponent("tests.conflicting.mary").path))
        #expect(library.snapshot().records.map(\.id) == [PackageID("tests.original")])
    }

    @Test func importShadowsImmutableDefinitionButNeverOverwritesLocalCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let base = Self.package(id: "tests.import", title: "Immutable base")
        try fixture.write(base, named: "base.mary", to: fixture.source)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
                .init(directory: fixture.installed, source: .installed, priority: 100),
            ],
            installedDirectory: fixture.installed)

        let importedURL = fixture.root.appendingPathComponent("portable.mary")
        let imported = Self.package(id: "tests.import", title: "Imported customization")
        try AbilityPackageCodec.encoded(imported).write(to: importedURL, options: .atomic)
        let first = try library.importPackage(from: importedURL)
        let installedURL = fixture.installed
            .appendingPathComponent("tests.import.mary")
        let installedBytes = try Data(contentsOf: installedURL)

        #expect(first.activated)
        #expect(first.snapshot.package(id: "tests.import")?.sourceURL.standardizedFileURL
            == installedURL.standardizedFileURL)
        #expect(first.snapshot.package(id: "tests.import")?.package.ability.title
            == "Imported customization")

        var replacement = imported
        replacement.ability.title = "Accidental overwrite"
        let replacementURL = fixture.root.appendingPathComponent("replacement.mary")
        try AbilityPackageCodec.encoded(replacement).write(
            to: replacementURL,
            options: .atomic)

        #expect(throws: AbilityLibraryError.packageAlreadyInstalled("tests.import")) {
            _ = try library.importPackage(from: replacementURL)
        }
        #expect(try Data(contentsOf: installedURL) == installedBytes)
        #expect(library.snapshot().package(id: "tests.import")?.package.ability.title
            == "Imported customization")
    }

    @Test func importRefusesExistingStudioOverrideWithoutChangingActivePackage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let overrideDirectory = AbilityLibrary.localOverrideDirectory(for: fixture.installed)
        try FileManager.default.createDirectory(
            at: overrideDirectory,
            withIntermediateDirectories: true)
        let customized = Self.package(id: "tests.override-import", title: "My customization")
        let overrideURL = overrideDirectory.appendingPathComponent("custom-name.mary")
        try AbilityPackageCodec.encoded(customized).write(to: overrideURL, options: .atomic)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)

        let incoming = Self.package(id: "tests.override-import", title: "Incoming")
        let incomingURL = fixture.root.appendingPathComponent("incoming.mary")
        try AbilityPackageCodec.encoded(incoming).write(to: incomingURL, options: .atomic)
        let originalBytes = try Data(contentsOf: overrideURL)

        #expect(throws: AbilityLibraryError.packageAlreadyInstalled("tests.override-import")) {
            _ = try library.importPackage(from: incomingURL)
        }
        #expect(try Data(contentsOf: overrideURL) == originalBytes)
        #expect(library.snapshot().package(id: "tests.override-import")?.package.ability.title
            == "My customization")
    }

    @Test func draftValidationUsesProspectiveGraphAndRuntimeVersion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Self.package(
            id: "tests.original",
            title: "Original",
            invocation: "shared_invocation")
        try fixture.write(original, named: "original.mary", to: fixture.source)
        let library = AbilityLibrary(
            fileManager: .default,
            runtimeVersion: "1.0.0")
        let loaded = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        #expect(loaded.activated)

        let conflicting = Self.package(
            id: "tests.conflicting",
            title: "Conflicting",
            invocation: "shared_invocation")
        let conflictJSON = try #require(String(
            data: AbilityPackageCodec.encoded(conflicting),
            encoding: .utf8))
        let conflict = library.validate(json: conflictJSON)
        #expect(!conflict.isValid)
        #expect(conflict.issues.contains { $0.code == "duplicate-invocation" })

        var future = Self.package(
            id: "tests.future",
            title: "Future",
            invocation: "inspect_future")
        future.package.minimumMaryVersion = "9.0.0"
        let futureJSON = try #require(String(
            data: AbilityPackageCodec.encoded(future),
            encoding: .utf8))
        let compatibility = library.validate(json: futureJSON)
        #expect(!compatibility.isValid)
        #expect(compatibility.issues.contains { $0.code == "minimum-mary-version" })

        var replacement = original
        replacement.ability.title = "Replacement"
        let replacementJSON = try #require(String(
            data: AbilityPackageCodec.encoded(replacement),
            encoding: .utf8))
        #expect(library.validate(json: replacementJSON).isValid)
    }

    @Test func studioEditCreatesOverrideWithoutChangingSourcePackage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceURL = fixture.source.appendingPathComponent("portable.mary")
        try fixture.write(
            Self.package(id: "tests.portable", title: "Bundled"),
            named: sourceURL.lastPathComponent,
            to: fixture.source)
        let originalBytes = try Data(contentsOf: sourceURL)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        let loaded = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        #expect(loaded.activated)

        let session = try library.beginEditingPackage(id: "tests.portable")
        #expect(session.createsLocalOverride)
        let localDraft = try AbilityPackageCodec.decode(
            try #require(session.draftJSON.data(using: .utf8)))
        #expect(localDraft.package.publisher == "local")
        #expect(localDraft.integrity?.isSigned == false)

        let saved = try library.saveEditedPackage(
            json: try Self.edited(session.draftJSON, title: "My portable Ability"),
            session: session)
        let overrideURL = AbilityLibrary.localOverrideDirectory(for: fixture.installed)
            .appendingPathComponent("tests.portable.mary")
        #expect(saved.activated)
        #expect(saved.snapshot.package(id: "tests.portable")?.sourceURL
            .resolvingSymlinksInPath() == overrideURL.resolvingSymlinksInPath())
        #expect(saved.snapshot.package(id: "tests.portable")?.package.ability.title
            == "My portable Ability")
        #expect(try Data(contentsOf: sourceURL) == originalBytes)
    }

    @Test func studioExportUsesValidatedPinnedDraftEvenAfterSourceChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceURL = fixture.source.appendingPathComponent("export.mary")
        try fixture.write(
            Self.package(id: "tests.export", title: "Visible source"),
            named: sourceURL.lastPathComponent,
            to: fixture.source)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        let session = try library.beginEditingPackage(id: "tests.export")
        let visibleDraft = try Self.edited(
            session.draftJSON,
            title: "Unsaved visible draft")

        // Export is a non-destructive copy, so a stale save lease must not
        // cause it to fall back to either the old registry or new disk bytes.
        try fixture.write(
            Self.package(id: "tests.export", title: "External source edit"),
            named: sourceURL.lastPathComponent,
            to: fixture.source)
        let exportURL = fixture.root.appendingPathComponent("portable-copy")
        try library.exportEditedPackage(
            json: visibleDraft,
            session: session,
            to: exportURL)
        let exportedURL = exportURL.appendingPathExtension("mary")
        let exported = try AbilityPackageCodec.load(from: exportedURL)

        #expect(exported.ability.title == "Unsaved visible draft")
        #expect(exported.package.id == "tests.export")
        #expect(try Data(contentsOf: sourceURL) != Data(contentsOf: exportedURL))
    }

    @Test func studioExportRejectsInvalidDraftWithoutCreatingFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            Self.package(id: "tests.invalid-export", title: "Source"),
            named: "source.mary",
            to: fixture.source)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        let session = try library.beginEditingPackage(id: "tests.invalid-export")
        let destination = fixture.root.appendingPathComponent("invalid.mary")

        #expect(throws: AbilityLibraryError.self) {
            try library.exportEditedPackage(
                json: "{ not valid json",
                session: session,
                to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func studioExportCannotBypassSaveByTargetingEditedPackage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let localURL = fixture.installed.appendingPathComponent("local.mary")
        try fixture.write(
            Self.package(id: "tests.export-source", title: "Installed"),
            named: localURL.lastPathComponent,
            to: fixture.installed)
        let originalBytes = try Data(contentsOf: localURL)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.installed, source: .installed, priority: 100),
            ],
            installedDirectory: fixture.installed)
        let session = try library.beginEditingPackage(id: "tests.export-source")

        #expect(throws: AbilityLibraryError.exportWouldOverwriteEditedPackage) {
            try library.exportEditedPackage(
                json: try Self.edited(session.draftJSON, title: "Unsaved"),
                session: session,
                to: localURL)
        }
        #expect(try Data(contentsOf: localURL) == originalBytes)
    }

    @Test func externalFilesystemChangeReloadsRegistryWithoutManualReload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceURL = fixture.source.appendingPathComponent("observed.mary")
        try fixture.write(
            Self.package(id: "tests.observed", title: "Before"),
            named: sourceURL.lastPathComponent,
            to: fixture.source)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        let initial = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        let initialRevision = initial.snapshot.revision

        try fixture.write(
            Self.package(id: "tests.observed", title: "After"),
            named: sourceURL.lastPathComponent,
            to: fixture.source)

        for _ in 0..<60 {
            if library.snapshot().package(id: "tests.observed")?.package.ability.title
                == "After" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(library.snapshot().revision != initialRevision)
        #expect(library.snapshot().package(id: "tests.observed")?.package.ability.title
            == "After")
    }

    @Test func externalInstalledAndOverrideChangesBothReloadWithoutManualReload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            Self.package(id: "tests.layers", title: "Source"),
            named: "source.mary",
            to: fixture.source)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)

        try fixture.write(
            Self.package(id: "tests.layers", title: "Imported layer"),
            named: "imported.mary",
            to: fixture.installed)
        for _ in 0..<60 {
            if library.snapshot().package(id: "tests.layers")?.package.ability.title
                == "Imported layer" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(library.snapshot().package(id: "tests.layers")?.package.ability.title
            == "Imported layer")

        let overrideDirectory = AbilityLibrary.localOverrideDirectory(for: fixture.installed)
        try fixture.write(
            Self.package(id: "tests.layers", title: "Studio override"),
            named: "override.mary",
            to: overrideDirectory)
        for _ in 0..<60 {
            if library.snapshot().package(id: "tests.layers")?.package.ability.title
                == "Studio override" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(library.snapshot().package(id: "tests.layers")?.package.ability.title
            == "Studio override")
    }

    @Test func studioEditOfSignedInstallPreservesSignedOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = Self.package(id: "tests.signed", title: "Signed")
        let signed = try AbilityPackageCodec.signed(
            package,
            privateKey: Curve25519.Signing.PrivateKey())
        let signedURL = fixture.installed.appendingPathComponent("tests.signed.mary")
        let signedBytes = try Self.portableJSON(signed)
        try signedBytes.write(to: signedURL, options: .atomic)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        let loaded = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.installed, source: .installed, priority: 100),
            ],
            installedDirectory: fixture.installed)
        #expect(loaded.activated)
        #expect(loaded.snapshot.package(id: "tests.signed")?.isSigned == true)

        let session = try library.beginEditingPackage(id: "tests.signed")
        #expect(session.createsLocalOverride)
        let saved = try library.saveEditedPackage(
            json: try Self.edited(session.draftJSON, title: "Locally tuned"),
            session: session)

        #expect(saved.activated)
        #expect(saved.snapshot.package(id: "tests.signed")?.isSigned == false)
        #expect(saved.snapshot.package(id: "tests.signed")?.package.ability.title
            == "Locally tuned")
        #expect(try Data(contentsOf: signedURL) == signedBytes)
        #expect(try AbilityPackageCodec.load(from: signedURL).integrity?.isSigned == true)
    }

    @Test func studioEditRejectsOverrideCreatedAfterEditingBegan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            Self.package(id: "tests.concurrent", title: "Source"),
            named: "concurrent.mary",
            to: fixture.source)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        let session = try library.beginEditingPackage(id: "tests.concurrent")
        let overrideDirectory = AbilityLibrary.localOverrideDirectory(for: fixture.installed)
        try FileManager.default.createDirectory(
            at: overrideDirectory,
            withIntermediateDirectories: true)
        var external = Self.package(id: "tests.concurrent", title: "External edit")
        external.package.publisher = "local"
        let externalURL = overrideDirectory.appendingPathComponent("tests.concurrent.mary")
        let externalBytes = try AbilityPackageCodec.encoded(external)
        try externalBytes.write(to: externalURL, options: .atomic)

        #expect(throws: AbilityLibraryError.externalModification) {
            _ = try library.saveEditedPackage(
                json: try Self.edited(session.draftJSON, title: "Studio edit"),
                session: session)
        }
        #expect(try Data(contentsOf: externalURL) == externalBytes)
        // The rejected draft must never activate. The exact active title is
        // deliberately NOT pinned to "Source": the override directory is an
        // observed root, so the library's own debounced file watcher may have
        // legitimately activated the external override by now — that race is
        // the watcher doing its job, not a leak of the studio draft.
        let activeTitle = library.snapshot()
            .package(id: "tests.concurrent")?.package.ability.title
        #expect(activeTitle == "Source" || activeTitle == "External edit")
        #expect(activeTitle != "Studio edit")
    }

    @Test func studioEditRejectsWhitespaceOnlyChangeToDirectLocalFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let localURL = fixture.installed.appendingPathComponent("direct.mary")
        try fixture.write(
            Self.package(id: "tests.direct", title: "Direct local"),
            named: localURL.lastPathComponent,
            to: fixture.installed)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.installed, source: .installed, priority: 100),
            ],
            installedDirectory: fixture.installed)

        let session = try library.beginEditingPackage(id: "tests.direct")
        #expect(!session.createsLocalOverride)
        let reformatted = try Self.appendingJSONWhitespace(to: localURL)
        #expect(try AbilityPackageCodec.load(from: localURL).package.id == "tests.direct")

        #expect(throws: AbilityLibraryError.externalModification) {
            _ = try library.saveEditedPackage(
                json: try Self.edited(session.draftJSON, title: "Studio edit"),
                session: session)
        }
        #expect(try Data(contentsOf: localURL) == reformatted)
    }

    @Test func studioEditRejectsWhitespaceOnlyChangeToImmutableSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceURL = fixture.source.appendingPathComponent("source.mary")
        try fixture.write(
            Self.package(id: "tests.source", title: "Source"),
            named: sourceURL.lastPathComponent,
            to: fixture.source)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)

        let session = try library.beginEditingPackage(id: "tests.source")
        #expect(session.createsLocalOverride)
        let reformatted = try Self.appendingJSONWhitespace(to: sourceURL)
        #expect(try AbilityPackageCodec.load(from: sourceURL).package.id == "tests.source")

        #expect(throws: AbilityLibraryError.externalModification) {
            _ = try library.saveEditedPackage(
                json: try Self.edited(session.draftJSON, title: "Studio edit"),
                session: session)
        }
        let overrideURL = AbilityLibrary.localOverrideDirectory(for: fixture.installed)
            .appendingPathComponent("tests.source.mary")
        #expect(try Data(contentsOf: sourceURL) == reformatted)
        #expect(!FileManager.default.fileExists(atPath: overrideURL.path))
    }

    @Test func studioEditRejectsWhitespaceOnlyChangeToExistingOverrideDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            Self.package(id: "tests.destination", title: "Source"),
            named: "destination.mary",
            to: fixture.source)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)

        let overrideDirectory = AbilityLibrary.localOverrideDirectory(for: fixture.installed)
        try FileManager.default.createDirectory(
            at: overrideDirectory,
            withIntermediateDirectories: true)
        var external = Self.package(id: "tests.destination", title: "External override")
        external.package.publisher = "local"
        let overrideURL = overrideDirectory.appendingPathComponent("tests.destination.mary")
        let existingBytes = try AbilityPackageCodec.encoded(external)
        try existingBytes.write(to: overrideURL, options: .atomic)

        // Whether observation has already activated it or not, Studio opens
        // the pre-existing override's exact bytes and leases that same file.
        let session = try library.beginEditingPackage(id: "tests.destination")
        #expect(Data(session.draftJSON.utf8) == existingBytes)
        #expect(try AbilityPackageCodec.decode(Data(session.draftJSON.utf8))
            .ability.title == "External override")
        let reformatted = try Self.appendingJSONWhitespace(to: overrideURL)
        #expect(try AbilityPackageCodec.load(from: overrideURL).package.id == "tests.destination")

        #expect(throws: AbilityLibraryError.externalModification) {
            _ = try library.saveEditedPackage(
                json: try Self.edited(session.draftJSON, title: "Studio edit"),
                session: session)
        }
        #expect(try Data(contentsOf: overrideURL) == reformatted)
    }

    @Test func studioEditAdoptsPreExistingOverrideBeforeSaving() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceURL = fixture.source.appendingPathComponent("adopt.mary")
        try fixture.write(
            Self.package(id: "tests.adopt", title: "Active base"),
            named: sourceURL.lastPathComponent,
            to: fixture.source)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        _ = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        #expect(library.snapshot().package(id: "tests.adopt")?.package.ability.title
            == "Active base")

        let overrideDirectory = AbilityLibrary.localOverrideDirectory(for: fixture.installed)
        try FileManager.default.createDirectory(
            at: overrideDirectory,
            withIntermediateDirectories: true)
        var unseen = Self.package(id: "tests.adopt", title: "Unseen local work")
        unseen.package.publisher = "local"
        let overrideURL = overrideDirectory.appendingPathComponent("tests.adopt.mary")
        var unseenBytes = try AbilityPackageCodec.encoded(unseen)
        unseenBytes.append(contentsOf: "\n \n".utf8)
        try unseenBytes.write(to: overrideURL, options: .atomic)

        let session = try library.beginEditingPackage(id: "tests.adopt")
        #expect(Data(session.draftJSON.utf8) == unseenBytes)
        #expect(try AbilityPackageCodec.decode(Data(session.draftJSON.utf8))
            .ability.title == "Unseen local work")

        let saved = try library.saveEditedPackage(
            json: try Self.edited(session.draftJSON, title: "Continued local work"),
            session: session)
        #expect(saved.activated)
        #expect(saved.snapshot.package(id: "tests.adopt")?.package.ability.title
            == "Continued local work")
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    }

    @Test func concurrentAdapterPublishesCannotActivateAStaleInventory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let library = AbilityLibrary(
            fileManager: .default,
            runtimeVersion: "1.0.0")
        let loaded = library.configureAndLoad(
            adapterManifests: [],
            locations: [
                .init(directory: fixture.source, source: .sourceTree, priority: 20),
            ],
            installedDirectory: fixture.installed)
        #expect(loaded.activated)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    _ = library.publishAdapterManifest(.init(
                        adapterID: AdapterID("tests.adapter-\(index)"),
                        title: "Adapter \(index)",
                        transport: .native))
                }
            }
        }

        let activeIDs = Set(library.snapshot().adapterManifests.map(\.adapterID))
        #expect(activeIDs.count == 24)
        for index in 0..<24 {
            #expect(activeIDs.contains(AdapterID("tests.adapter-\(index)")))
        }
    }

    private static func package(
        id: PackageID,
        title: String,
        invocation: String = "inspect_fixture"
    ) -> MaryAbilityPackage {
        let skillID = SkillID("\(id.rawValue).inspect")
        let ability = AbilitySchema(
            id: AbilityID(id.rawValue),
            title: title,
            summary: "Portable test Ability.",
            tint: "#123456",
            skills: [skillID])
        let skill = SkillSchema(
            id: skillID,
            title: "Inspect",
            summary: "Inspect the fixture.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: invocation))
        return MaryAbilityPackage(
            package: .init(
                id: id,
                version: "1.0.0",
                publisher: "tests",
                summary: "AbilityLibrary test package."),
            ability: ability,
            skills: [skill])
    }

    private static func edited(_ json: String, title: String) throws -> String {
        var package = try AbilityPackageCodec.decode(
            try #require(json.data(using: .utf8)),
            verifyIntegrity: false)
        package.ability.title = title
        return try #require(String(
            data: AbilityPackageCodec.encoded(package),
            encoding: .utf8))
    }

    private static func portableJSON(_ package: MaryAbilityPackage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(package)
    }

    @discardableResult
    private static func appendingJSONWhitespace(to url: URL) throws -> Data {
        var data = try AbilityPackageCodec.contents(of: url)
        data.append(contentsOf: "\n \n".utf8)
        try data.write(to: url, options: .atomic)
        return data
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let installed: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mary-ability-library-\(UUID().uuidString)", isDirectory: true)
            source = root.appendingPathComponent("source", isDirectory: true)
            installed = root.appendingPathComponent("installed", isDirectory: true)
            try FileManager.default.createDirectory(
                at: source,
                withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: installed,
                withIntermediateDirectories: true)
        }

        func write(
            _ package: MaryAbilityPackage,
            named name: String,
            to directory: URL
        ) throws {
            try AbilityPackageCodec.encoded(package).write(
                to: directory.appendingPathComponent(name),
                options: .atomic)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

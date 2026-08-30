//
//  AbilityLibraryTests.swift
//  MaryBrainTests
//
//  WHAT: Install override + integrity-graph rollback.
//  OUT:  AbilityLibrary
//

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

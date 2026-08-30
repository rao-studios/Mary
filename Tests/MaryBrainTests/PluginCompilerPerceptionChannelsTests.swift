//
//  PluginCompilerPerceptionChannelsTests.swift
//  MaryBrainTests
//
//  WHAT: All four observation channels earn a workspace perception claim.
//  OUT:  PluginCompiler.perception
//  PIN:  corpus and mediaSurface must not silently downgrade to perceptionOnly
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct PluginCompilerPerceptionChannelsTests {

    private func loadRootPackage(_ name: String) throws -> MaryAbilityPackage {
        guard let abilities = InstalledPackages.installed() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let candidate = abilities.appendingPathComponent("\(name).mary")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try AbilityPackageCodec.load(from: candidate)
    }

    /// One assertion, reused for all four channels: the compiled profile's
    /// perception is `.workspace` (never downgraded to `.perceptionOnly`),
    /// and the `AmbientPlace` it registers reports `hasEyes` — the exact
    /// property `ApplicationRegistration.hasEyes` derives from
    /// `perception.observesDocuments`, which only `readsDocumentCorpus` (set
    /// exclusively on the `.workspace` arm) can satisfy for a Dynamic
    /// Plugin.
    private func assertEarnsWorkspaceEyes(
        applicationID: String, packages: [MaryAbilityPackage],
        bundleIdentifiers: Set<String>, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let compilation = PluginCompiler.compile(
            packages: packages, nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })
        let profile = try #require(
            compilation.applicationProfiles.first { $0.id == applicationID },
            "no compiled profile for \(applicationID)", sourceLocation: sourceLocation)
        let perception = try #require(
            profile.perception, "\(applicationID) compiled no perception at all",
            sourceLocation: sourceLocation)
        #expect(
            perception.kind == .workspace,
            "\(applicationID) downgraded to \(perception.kind) — the exact regression this test pins",
            sourceLocation: sourceLocation)

        try AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([
                ApplicationRegistration(
                    id: applicationID, profile: profile,
                    bundleIdentifiers: bundleIdentifiers,
                    worldClass: .workspace, displayName: profile.title,
                    perception: perception),
            ])
        ) {
            let place = AmbientPlace.application(applicationID)
            #expect(
                place.hasEyes,
                "\(applicationID) has no eyes — a workspace claim with nothing behind it",
                sourceLocation: sourceLocation)
        }
    }

    // MARK: - Channel 1: proseSurface (never broken — the compiler's original arm)

    @Test func proseSurfaceEarnsWorkspaceEyes() throws {
        guard InstalledPackages.installed() != nil else { return }
        try assertEarnsWorkspaceEyes(
            applicationID: "textedit",
            packages: [try loadRootPackage("textedit"), try loadRootPackage("writing")],
            bundleIdentifiers: ["com.apple.TextEdit"])
    }

    // MARK: - Channel 2: codeSurface (never broken — added in [Corpus H])

    @Test func codeSurfaceEarnsWorkspaceEyes() throws {
        guard InstalledPackages.installed() != nil else { return }
        try assertEarnsWorkspaceEyes(
            applicationID: "xcode",
            packages: [try loadRootPackage("xcode"), try loadRootPackage("coding")],
            bundleIdentifiers: ["com.apple.dt.Xcode"])
    }

    // MARK: - Channel 3: mediaSurface — THIS FIX

    /// `apple-music.mary` declares no `proseSurface` and no `codeSurface` —
    /// only `mediaSurface`. Before this fix, `perception(from:proseSurface:
    /// codeSurface:)`'s two-parameter guard never saw it and downgraded
    /// every taught media player to `.perceptionOnly`.
    @Test func mediaSurfaceEarnsWorkspaceEyes() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("apple-music")
        #expect(
            package.plugin?.proseSurface == nil && package.plugin?.codeSurface == nil,
            "apple-music.mary grew a prose/code surface — this test no longer isolates the media channel")
        #expect(
            package.plugin?.mediaSurface != nil,
            "apple-music.mary no longer declares a mediaSurface — this test has nothing to prove")
        try assertEarnsWorkspaceEyes(
            applicationID: "apple-music",
            // `apple-music.mary` realizes `multimedia.open-player` — it
            // needs `multimedia.mary` in the graph for `PluginCompiler
            // .compile` to resolve that realization's owner, the same
            // reason `corpusEarnsWorkspaceEyes` below loads `writing.mary`
            // alongside `scrivener.mary`.
            packages: [package, try loadRootPackage("multimedia")],
            bundleIdentifiers: ["com.apple.Music"])
    }

    // MARK: - Channel 4: corpus — THIS FIX, and the one behind the reported bug

    /// `scrivener.mary` declares no `proseSurface` and no `codeSurface` —
    /// only `corpus`. This is the exact package the reported bug named:
    /// `type_at_cursor` refusing "I couldn't find a text cursor" in
    /// Scrivener because `hasEyes` came back false despite the package
    /// validating cleanly.
    @Test func corpusEarnsWorkspaceEyes() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("scrivener")
        #expect(
            package.plugin?.proseSurface == nil && package.plugin?.codeSurface == nil,
            "scrivener.mary grew a prose/code surface — this test no longer isolates the corpus channel")
        #expect(
            package.plugin?.corpus != nil,
            "scrivener.mary no longer declares a corpus — this test has nothing to prove")
        try assertEarnsWorkspaceEyes(
            applicationID: "scrivener",
            packages: [package, try loadRootPackage("writing")],
            bundleIdentifiers: ["com.literatureandlatte.scrivener"])
    }

    // MARK: - The other half: a workspace claim with NONE of the four still degrades

    /// THE GUARD THE FIX MUST NOT REMOVE. A package that somehow reaches
    /// compilation with a `workspace` perception claim and none of the four
    /// channels — the validator's own admission gate refuses this at
    /// package load, but the compiler's downgrade is the second, independent
    /// line the doc comment on `perception(from:...)` names ("THE SURFACE IS
    /// CHECKED HERE, NOT ONLY IN THE VALIDATOR") — must still degrade to
    /// `.perceptionOnly` rather than being handed eyes with nothing behind
    /// them. `writing.mary` itself names no applications and realizes no
    /// surface, so its own (nonexistent) plugin profile is not exercised
    /// here; instead this loads `xcode.mary` and strips its `codeSurface`
    /// via a re-encoded copy, the same "break one field" pattern
    /// `PackageFixtures`'s own header describes.
    @Test func aWorkspaceClaimWithNoChannelStillDegradesToPerceptionOnly() throws {
        guard InstalledPackages.installed() != nil else { return }
        var xcode = try loadRootPackage("xcode")
        guard var plugin = xcode.plugin else {
            Issue.record("xcode.mary has no plugin to strip")
            return
        }
        #expect(plugin.application.perception?.kind == .workspace)
        plugin.codeSurface = nil
        plugin.proseSurface = nil
        plugin.mediaSurface = nil
        plugin.corpus = nil
        xcode.plugin = plugin

        let compilation = PluginCompiler.compile(
            packages: [xcode, try loadRootPackage("coding")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })
        let profile = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })
        let perception = try #require(profile.perception)
        #expect(
            perception.kind == .perceptionOnly,
            "a workspace claim backed by none of the four channels must still degrade")
    }
}

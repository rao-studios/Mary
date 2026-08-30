//
//  AbilityRuntimeVersionTests.swift
//  MaryBrainTests
//
//  THE APP'S VERSION AND THE PACKAGES' FLOOR, held against each other.
//
//  THE FAILURE THIS PREVENTS, because it already happened: `Support/Info.plist`
//  said `0.1.0` while every shipped `.mary` package declared
//  `"minimumMaryVersion": "1.0.0"`. `AbilityLibrary.detectedRuntimeVersion`
//  reads that plist key, so inside `Mary.app` the runtime called itself older
//  than everything it was asked to load — one `minimum-mary-version` error per
//  package — and the all-or-nothing guard in `reload()` rejected the entire
//  graph. Ability Studio opened empty and offered to help by suggesting the
//  user add a package to a folder that already held seven.
//
//  IT LOOKED INTERMITTENT, which is the reason it survived: `swift run` and a
//  bare `.build/debug/Mary` have no Info.plist at all, so
//  `detectedRuntimeVersion` falls back to `"1.0.0"` and the gate passes. Only
//  the assembled bundle — the way the app is actually used, because that is
//  what owns its own TCC identity — carried the failing number. Every test in
//  the suite was green while the shipping app loaded nothing.
//
//  Two numbers in two unrelated files, with nothing relating them, is how they
//  drifted. This is the relation.
//

import Foundation
import MaryFoundation
import Testing
@testable import MaryBrain

@Suite struct AbilityRuntimeVersionTests {

    /// The app bundle's `CFBundleShortVersionString` — the exact string
    /// `AbilityLibrary.detectedRuntimeVersion` reads out of `Bundle.main` once
    /// `scripts/make-app.sh` has copied this plist into `Mary.app`.
    ///
    /// FOUND BY SHAPE, not by counting directories up from this file, for the
    /// reason `AbilityLibrary.repositoryRoot(from:)` documents at length: a
    /// path derived from a hop count breaks the day someone reorganizes files,
    /// and breaks by pointing somewhere plausible rather than by failing.
    static func bundleShortVersion() throws -> String? {
        guard let root = AbilityLibrary.repositoryRoot(from: #filePath) else { return nil }
        let plist = root
            .appendingPathComponent("Support", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plist)
        let values = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        return values?["CFBundleShortVersionString"] as? String
    }

    @Test func theAppBundleIsNewerThanEveryPackageItShips() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let declared = try Self.bundleShortVersion()
        let shortVersion = try #require(
            declared, "Support/Info.plist declares no CFBundleShortVersionString")
        let runtime = SemanticVersion(shortVersion)

        let packages = try FileManager.default
            .contentsOfDirectory(at: abilities, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mary" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!packages.isEmpty, "Abilities/ holds no .mary packages")

        // THE SAME COMPARISON THE LOADER MAKES, in
        // AbilityLibrary+PackageLifecycle.swift — not an approximation of it. A
        // test that asked a looser question would pass while the gate it stands
        // for refused the package.
        for url in packages {
            let package = try AbilityPackageCodec.load(from: url)
            guard let minimum = package.package.minimumMaryVersion else { continue }
            #expect(
                !(runtime < minimum),
                """
                \(url.lastPathComponent) requires Mary \(minimum.rawValue), but \
                Support/Info.plist declares \(shortVersion). Inside Mary.app this \
                is a minimum-mary-version error, and one error rejects the whole \
                registry — no Abilities load at all.
                """)
        }
    }

    /// An UNPARSEABLE version string is worse than a wrong one. `<` falls back
    /// to comparing raw strings when either side does not parse, so a plist
    /// reading "1.0" or "1.0.0-dev build 3" would silently gate packages on
    /// alphabetical order and be right often enough to look fine.
    @Test func theBundleVersionIsAParseableSemanticVersion() throws {
        guard InstalledPackages.installed() != nil else { return }
        let declared = try Self.bundleShortVersion()
        let shortVersion = try #require(
            declared, "Support/Info.plist declares no CFBundleShortVersionString")
        #expect(
            SemanticVersion.isValid(shortVersion),
            """
            CFBundleShortVersionString '\(shortVersion)' is not a semantic \
            version; version comparison would fall back to string ordering.
            """)
    }
}

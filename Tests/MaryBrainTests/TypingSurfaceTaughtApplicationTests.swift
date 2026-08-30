//
//  TypingSurfaceTaughtApplicationTests.swift
//  MaryBrainTests
//
//  THE SAME BUG CLASS AS `WritingReachabilityTests
//  .theRealScrivener3BundleIDIsRecognizedAsTheScrivenerApplication`, FOUND
//  AGAIN IN A DIFFERENT CODE PATH.
//
//  `[Corpus F]` fixed exact-vs-family bundle id matching for the AMBIENT/
//  ROUTING lane: `scrivener.mary` gained `plugin.application
//  .bundleIdentifierPrefix`, and `ApplicationRegistration.owns(bundleID:)`
//  reads it. `TypingModels.swift`'s `TypingSurface.taughtSurface(named:)`
//  is a SEPARATE resolver — it does not go through `ApplicationRegistration
//  .owns(bundleID:)` at all — and it built its `TypingSurface` with
//  `matchPrefix == bundleID`, the package's exact DECLARED id
//  (`com.literatureandlatte.scrivener`), never reading the same
//  `bundleIdentifierPrefix` field. `TypingSurface.isRunning` then compared
//  that declared id exactly against every running process, so it answered
//  false against the real, installed Scrivener 3
//  (`com.literatureandlatte.scrivener3`).
//
//  THE SYMPTOM: an explicit `app: "Scrivener"` argument to `type_at_cursor`
//  — the only path that resolves through `taughtSurface(named:)` — misfired
//  "Open Scrivener first" with Scrivener genuinely running. The frontmost
//  rung (no explicit `app`, what an ordinary conversational turn takes with
//  Scrivener already in front) never touches `taughtSurface` and was always
//  fine — `ScrivenerPerceptionProbe`'s live dispatch pins exactly that rung.
//
//  THE FIX reuses the SAME mechanism `[Corpus F]` used, not a new one:
//  `taughtSurface(named:)` now carries `registration.bundleIdentifierPrefix`
//  as `TypingSurface.matchPrefix`, and `TypingSurface.isRunning` reads it
//  through the identical boundary predicate ambient routing already trusts,
//  `ApplicationRegistration.isInFamily`.
//
//  PURE AND DETERMINISTIC, like `[Corpus F]`'s own pin: this proves the
//  MECHANISM (the family prefix is carried, and the boundary predicate
//  admits the real Scrivener 3 id) without depending on any process actually
//  being open, so it cannot flake in CI.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct TypingSurfaceTaughtApplicationTests {

    @Test func explicitAppArgumentResolvesTheRealScrivener3BundleID() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [try loadRootPackage("scrivener"), try loadRootPackage("writing")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let profile = try #require(
            compilation.applicationProfiles.first { $0.id == "scrivener" })
        let registration = AmbientApplicationBridge.registration(for: profile)

        // EVERYTHING BELOW RUNS WITH THE ROSTER INSTALLED: `registration
        // .place.focus` (like `AmbientPlace.hasEyes`) looks its own
        // registration back up through `AmbientApplicationIndexProvider`, so
        // it answers nil outside the scope — same reason `taughtSurface`
        // itself has to run in here.
        let (surface, hasEyes, focus) = AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([registration])
        ) {
            (
                TypingSurface.taughtSurface(named: "scrivener"),
                registration.hasEyes,
                registration.place.focus
            )
        }
        try #require(
            hasEyes,
            "the taught-surface rung is gated on eyes; this pin is worthless without them")
        try #require(focus == .writing, "and on the writing discipline")

        // THE EXPLICIT-APP PATH: `TypingSurface.resolve(requested:...)` tries
        // `taughtSurface(named:)` FIRST, before the running-applications
        // rung — exactly what "type_at_cursor" with an explicit
        // `app: "Scrivener"` argument exercises.
        let resolved = try #require(
            surface, "the roster must resolve the taught Scrivener application")
        #expect(
            resolved.bundleID == "com.literatureandlatte.scrivener",
            "launch/exact identity stays the declared id — a family cannot be launched")
        #expect(
            resolved.matchPrefix == "com.literatureandlatte.scrivener",
            """
            THE FIX: the declared family prefix must be carried onto the surface, not \
            silently dropped in favor of the exact id
            """)

        // THE REGRESSION ITSELF, run through `TypingSurface.isRunning`'s own
        // pure decision function — not a stand-in predicate. The running list
        // below holds ONLY the versioned Scrivener 3 id, deliberately never
        // the exact declared one: the pre-fix property was
        // `!NSRunningApplication.runningApplications(withBundleIdentifier:
        // bundleID).isEmpty` alone, an exact-only comparison that never
        // consulted `matchPrefix` at all, so this exact scenario is precisely
        // what it answered false for — "Open Scrivener first" against a
        // genuinely running Scrivener.
        #expect(
            TypingSurface.isRunning(
                bundleID: resolved.bundleID,
                matchPrefix: resolved.matchPrefix,
                runningBundleIdentifiers: ["com.literatureandlatte.scrivener3"]),
            """
            the real, installed Scrivener 3 process must resolve as this taught surface — \
            this is the exact scenario that used to misfire "Open Scrivener first"
            """)
        #expect(
            TypingSurface.isRunning(
                bundleID: resolved.bundleID,
                matchPrefix: resolved.matchPrefix,
                runningBundleIdentifiers: ["com.literatureandlatte.scrivener"]),
            "the exact declared id still resolves too")
        #expect(
            !TypingSurface.isRunning(
                bundleID: resolved.bundleID,
                matchPrefix: resolved.matchPrefix,
                runningBundleIdentifiers: ["com.example.scrivener"]),
            "a different vendor's app merely containing the name must not")
    }

    /// THE FRONTMOST RUNG MUST NOT REGRESS. It never routes through
    /// `taughtSurface(named:)` — `TypingSurface.resolve` only tries that rung
    /// when `requested` is non-nil — so a plain `TypingSurface` built the way
    /// every other rung already builds one (no explicit `matchPrefix`) must
    /// keep defaulting `matchPrefix` to the exact `bundleID`, unaffected by
    /// this fix.
    @Test func aSurfaceWithNoDeclaredFamilyStillDefaultsItsMatchPrefixToTheExactBundleID() {
        let surface = TypingSurface(bundleID: "com.example.notes", spokenName: "Notes")
        #expect(surface.matchPrefix == surface.bundleID)
    }

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
}

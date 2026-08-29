//
//  SurfaceRegistrationFamilyMatchingTests.swift
//  MaryPluginTests
//
//  THE SAME BUG CLASS, closed a fourth time: `[Corpus F]` (the ambient/
//  routing lane, `ApplicationRegistration.owns(bundleID:)`), `[Corpus M]`'s
//  underlying cause, and `[Corpus P]` (`TypingSurface.taughtSurface(named:)`,
//  see `TypingSurfaceTaughtApplicationTests.swift`) each found the identical
//  shape in a different code path: a registration compared a package's
//  EXACT declared bundle id against a running process, so a vendor who ships
//  a versioned id (`…scrivener3` beside a package declaring
//  `…scrivener`) read as "not running" even while genuinely open.
//
//  `[Corpus P]`'s own commit noted, rather than fixed, that
//  `MediaSurfaceRegistration.owns(bundleID:)` and
//  `CodeSurfaceRegistration.owns(bundleID:)` still had this exact shape —
//  nothing live broke because no currently-taught media or code package
//  declares a versioned id, so this is a proactive close, not an incident
//  response. Both registrations now carry an optional
//  `bundleIdentifierPrefix`, read through the identical boundary predicate
//  the other three fixes already trust: `ApplicationRegistration
//  .isInFamily`.
//
//  SYNTHETIC BY NECESSITY: unlike `[Corpus P]`, there is no real installed
//  application to reproduce this against, so these pins build each
//  registration directly (both types have a public, literal-friendly init)
//  with a fixture family — `com.example.player` / `com.example.player3` —
//  and prove the matching logic itself, not a live dispatch.
//

import Foundation
import Testing
import MaryFoundation
@testable import MaryPlugin

@Suite struct SurfaceRegistrationFamilyMatchingTests {

    // MARK: - MediaSurfaceRegistration

    @Test func mediaSurfaceRegistrationRecognizesAVersionedBundleIDInTheDeclaredFamily() {
        let registration = MediaSurfaceRegistration(
            applicationID: "player",
            bundleIdentifiers: ["com.example.player"],
            bundleIdentifierPrefix: "com.example.player",
            displayName: "Player",
            schema: PluginMediaSurfaceSchema(
                transportLabel: "Mini Player",
                playingLabel: "Pause",
                pausedLabel: "Play",
                shuffle: nil,
                repeatMode: nil,
                positionLabel: "Track Position"))

        #expect(
            registration.owns(bundleID: "com.example.player"),
            "the exact declared id must still resolve")
        #expect(
            registration.owns(bundleID: "com.example.player3"),
            """
            THE FIX: a next-major-version id inside the declared family must resolve too — \
            this is precisely the scenario the old exact-only comparison answered false for
            """)
        #expect(
            registration.owns(bundleID: "COM.EXAMPLE.PLAYER3"),
            "family matching stays case-insensitive, same as the exact rung always was")
        #expect(
            !registration.owns(bundleID: "com.example.playerling"),
            "a boundary match only — a different word after the prefix is a different app")
        #expect(
            !registration.owns(bundleID: "com.other.player"),
            "an unrelated vendor must never resolve")
    }

    @Test func mediaSurfaceRegistrationWithNoDeclaredFamilyStaysExactOnly() {
        let registration = MediaSurfaceRegistration(
            applicationID: "player",
            bundleIdentifiers: ["com.example.player"],
            displayName: "Player",
            schema: PluginMediaSurfaceSchema(
                transportLabel: "Mini Player",
                playingLabel: "Pause",
                pausedLabel: "Play",
                shuffle: nil,
                repeatMode: nil,
                positionLabel: "Track Position"))

        #expect(registration.owns(bundleID: "com.example.player"))
        #expect(
            !registration.owns(bundleID: "com.example.player3"),
            "no declared family means the exact id is the whole answer, unchanged from before")
    }

    // MARK: - CodeSurfaceRegistration

    @Test func codeSurfaceRegistrationRecognizesAVersionedBundleIDInTheDeclaredFamily() {
        let registration = CodeSurfaceRegistration(
            applicationID: "editor",
            bundleIdentifiers: ["com.example.editor"],
            bundleIdentifierPrefix: "com.example.editor",
            displayName: "Editor",
            schema: PluginCodeSurfaceSchema(
                handlePrefix: "C",
                editorRoles: [.textArea],
                documentKey: .documentPathThenWindow,
                budgets: PluginProseBudgetSchema(
                    wholeDocumentCharacters: 100,
                    regionCharacters: 50,
                    ambientExcerptCharacters: 20)))

        #expect(registration.owns(bundleID: "com.example.editor"))
        #expect(
            registration.owns(bundleID: "com.example.editor3"),
            """
            THE FIX: a next-major-version id inside the declared family must resolve too — \
            this is precisely the scenario the old exact-only comparison answered false for
            """)
        #expect(
            !registration.owns(bundleID: "com.example.editorling"),
            "a boundary match only — a different word after the prefix is a different app")
        #expect(!registration.owns(bundleID: "com.other.editor"))
    }

    @Test func codeSurfaceRegistrationWithNoDeclaredFamilyStaysExactOnly() {
        let registration = CodeSurfaceRegistration(
            applicationID: "editor",
            bundleIdentifiers: ["com.example.editor"],
            displayName: "Editor",
            schema: PluginCodeSurfaceSchema(
                handlePrefix: "C",
                editorRoles: [.textArea],
                documentKey: .documentPathThenWindow,
                budgets: PluginProseBudgetSchema(
                    wholeDocumentCharacters: 100,
                    regionCharacters: 50,
                    ambientExcerptCharacters: 20)))

        #expect(registration.owns(bundleID: "com.example.editor"))
        #expect(
            !registration.owns(bundleID: "com.example.editor3"),
            "no declared family means the exact id is the whole answer, unchanged from before")
    }
}

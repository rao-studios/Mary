//
//  CompiledAdapterHandshakeTests.swift
//  MaryBrainTests
//
//  THE HANDSHAKE BETWEEN A SHIPPED PACKAGE AND A SHIPPED ADAPTER, checked
//  against the real ones rather than a fixture.
//
//  Readiness is a JOIN: a Skill names the Capabilities it needs, each
//  Capability constrains how it may execute, and the adapter's manifest says
//  what its operations actually claim. Every one of those three can be
//  individually valid while the join produces nothing — which is why schema
//  tests, routing tests and package validation all passed while four of
//  `multimedia.mary`'s Skills were installed and unavailable:
//
//      control_playback is unavailable: Operation control_playback does not
//      implement an allowed target class: media-player.
//
//  `MediaSurfaceAdapter` had taken the protocol's DEFAULT manifest, which
//  publishes an operation's name and nothing else — no capabilities, no target
//  classes, no observed Perceptions. The Capabilities it was meant to satisfy
//  constrain themselves to `allowedTargetClass: media-player`, and an operation
//  that claims no class implements none of them.
//
//  IT PRESENTED AS SELECTIVE, which is what cost the time: `search_music` and
//  `play_music` stayed ready throughout, because their Capabilities constrain
//  no target class and the check never ran. A whole adapter silently
//  half-working looks like a bug in the two Skills that fail rather than a
//  missing declaration behind all six.
//
//  SCOPED TO COMPILED ADAPTERS ON PURPOSE. A Skill bound to a package-declared
//  plugin (`xcode.managed-ui`) or to an adapter this build does not ship
//  (`mac/open_app`) is allowed to be blocked — that is a missing lane, not a
//  broken handshake, and the packages say so themselves. What must never be
//  blocked is a Skill bound to an adapter Mary compiles in: both halves of that
//  join ship in this repository, so a mismatch between them is always a bug.
//

import Foundation
import Testing
@testable import MaryAdapters
@testable import MaryBrain

@Suite struct CompiledAdapterHandshakeTests {

    @Test func everySkillBoundToACompiledAdapterIsReady() throws {
        guard let abilities = InstalledPackages.installed() else { return }

        // THE REAL ROSTER, exactly as `installBrainConfiguration` builds it.
        // A hand-built manifest here would test the hand-built manifest.
        let adapters = MaryAdapterCatalog.adapters()
        let manifests = MaryAdapterCatalog.adapterManifests(
            adapters: adapters,
            observers: MaryAdapterCatalog.observers())
        let compiled = Set(manifests.map(\.adapterID))

        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        let report = library.configureAndLoad(
            adapterManifests: manifests,
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            locations: [.init(directory: abilities, source: .sourceTree, priority: 20)],
            installedDirectory: nil)
        #expect(report.activated, "the shipped packages did not activate")

        let joined = report.snapshot.skills.filter { skill in
            guard let adapterID = skill.reference.adapterID else { return false }
            return compiled.contains(adapterID)
        }
        #expect(!joined.isEmpty, "no shipped Skill binds to a compiled adapter")

        for skill in joined where skill.availability.readiness == .blocked {
            let adapter = skill.reference.adapterID?.rawValue ?? "—"
            let operation = skill.reference.bindingOperation ?? "—"
            Issue.record(
                """
                \(skill.skill.id.rawValue) → \(adapter)/\(operation) is blocked, but \
                both halves of that join ship in this repository: \
                \(skill.availability.reasons.joined(separator: " "))
                """)
        }
    }
}

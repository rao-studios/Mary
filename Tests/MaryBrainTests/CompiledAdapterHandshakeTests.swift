//
//  CompiledAdapterHandshakeTests.swift
//  MaryBrainTests
//
//  WHAT: Shipped package × compiled adapter join — blocked Skills are a missing declaration.
//  OUT:  AbilityAdapterCompatibilityEvaluator against MaryAdapterCatalog
//  PIN:  Package-declared plugins may be blocked; compiled adapters must not
//

import Foundation
import Testing
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct CompiledAdapterHandshakeTests {

    @Test func everySkillBoundToACompiledAdapterIsReady() throws {
        guard let abilities = InstalledPackages.installed() else { return }

        // THE REAL ROSTER, exactly as `installBrainConfiguration` builds it.
        // A hand-built manifest here would test the hand-built manifest.
        // THE REAL ROSTER, including faculties appended at the composition
        // root (Affordance, Looking, CodingAgent) — not catalogued as apps.
        let adapters = MaryAdapterCatalog.adapters()
            + [
                AffordancePlugin(),
                LookingPlugin { _ in SkillOutcome(ok: true, summary: "") },
                CodingAgentAdapter(),
            ]
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

//
//  DerivedPerceptionTests.swift
//  MaryBrainTests
//
//  WHAT: Concluded perceptions (code-workspace-focus, project-focus) are not missing lanes.
//  OUT:  DerivedPerceptions + inventory publishes(_:)
//

import Foundation
import Testing
@testable import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct DerivedPerceptionTests {

    // MARK: - The mechanism

    private func inventory(_ manifests: [InstalledAdapterManifest]) -> InstalledAdapterInventory {
        InstalledAdapterInventory(manifests: manifests, primitiveBindings: [])
    }

    @Test func derivedPerceptionIsPublishedWhenItsBaseIs() {
        let inventory = inventory([.init(
            adapterID: "test.workspace-observer",
            title: "Workspace Observer",
            transport: .native,
            providesPerceptions: [.workspaceFocus])])
        #expect(inventory.publishes(PerceptionID.workspaceFocus))
        #expect(inventory.publishes(PerceptionID.codeWorkspaceFocus))
        #expect(inventory.publishes(PerceptionID.projectFocus))
    }

    @Test func derivedPerceptionIsNotPublishedWithoutItsBase() {
        let inventory = inventory([.init(
            adapterID: "test.hover-observer",
            title: "Hover Observer",
            transport: .native,
            providesPerceptions: [.hover])])
        #expect(!inventory.publishes(PerceptionID.codeWorkspaceFocus))
        #expect(!inventory.publishes(PerceptionID.projectFocus))
    }

    @Test func underivedPerceptionGetsNoFallback() {
        // `text-surface-focus` is deliberately absent from the table — nothing
        // derives it. A base claim must not leak sideways into it.
        let inventory = inventory([.init(
            adapterID: "test.workspace-observer",
            title: "Workspace Observer",
            transport: .native,
            providesPerceptions: [.workspaceFocus])])
        #expect(!inventory.publishes(PerceptionID.textSurfaceFocus))
    }

    @Test func unavailableManifestDerivesNothing() {
        // The inventory only counts available manifests toward published
        // Perceptions; a derivation from an absent sensor would promise
        // evidence no turn will carry.
        let inventory = inventory([.init(
            adapterID: "test.workspace-observer",
            title: "Workspace Observer",
            transport: .native,
            providesPerceptions: [.workspaceFocus],
            isAvailable: false,
            unavailableReason: "The observer's application is not installed.")])
        #expect(!inventory.publishes(PerceptionID.workspaceFocus))
        #expect(!inventory.publishes(PerceptionID.codeWorkspaceFocus))
    }

    // MARK: - The table's honesty

    @Test func derivationRowsAreSingleHop() {
        for (derived, base) in DerivedPerceptions.base {
            #expect(derived != base, "\(derived.rawValue) derives from itself")
            #expect(
                DerivedPerceptions.base[base] == nil,
                """
                \(derived.rawValue) derives from \(base.rawValue), which is \
                itself derived — the runtime concludes in one hop, so a chain \
                is a row the runtime does not honor
                """)
        }
    }

    @Test func everyRowIsReachableFromTheCompiledRoster() {
        // THE REAL ROSTER, exactly as `installBrainConfiguration` builds it —
        // a hand-built manifest here would test the hand-built manifest.
        let manifests = MaryAdapterCatalog.adapterManifests(
            adapters: MaryAdapterCatalog.adapters(),
            observers: MaryAdapterCatalog.observers())
        let claimed = Set(manifests.flatMap(\.providesPerceptions))

        for (derived, base) in DerivedPerceptions.base {
            #expect(
                claimed.contains(base),
                """
                \(derived.rawValue) derives from \(base.rawValue), but no \
                compiled adapter claims \(base.rawValue) — the row can never \
                fire and un-blocks Skills whose evidence no turn will carry
                """)
            #expect(
                !claimed.contains(derived),
                """
                \(derived.rawValue) is statically claimed by a compiled \
                adapter — a derived Perception is a conclusion, and a manifest \
                claiming it makes two sources of truth
                """)
        }
    }

    @Test func theCompiledRosterPublishesEveryDerivedPerception() {
        // The join the bug broke, closed at the inventory level. Availability
        // is forced TRUE because this asserts the ROSTER's claims, not this
        // process's TCC grants — in a test runner without the Accessibility
        // grant every AX-backed adapter reports unavailable, which is an honest
        // fact about the process and says nothing about the manifests.
        let manifests = MaryAdapterCatalog.adapterManifests(
            adapters: MaryAdapterCatalog.adapters(),
            observers: MaryAdapterCatalog.observers()
        ).map { manifest in
            var available = manifest
            available.isAvailable = true
            return available
        }
        let inventory = inventory(manifests)
        for derived in DerivedPerceptions.base.keys {
            #expect(
                inventory.publishes(derived),
                "the compiled roster does not publish \(derived.rawValue), so every Skill requiring it installs `.blocked`")
        }
    }

    // In a runner WITHOUT the Accessibility grant this cannot bite: the
    // permission check marks AX-backed operations unavailable and the
    // evaluator returns before the Perception check ever runs. It stays as a
    // tripwire for granted environments (the Xcode scheme run from a granted
    // terminal), where the pre-fix failure signature appeared.
    @Test func noShippedSkillIsBlockedOnADerivedPerception() throws {
        guard let abilities = InstalledPackages.installed() else { return }

        let adapters = MaryAdapterCatalog.adapters()
        let manifests = MaryAdapterCatalog.adapterManifests(
            adapters: adapters,
            observers: MaryAdapterCatalog.observers())

        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        let report = library.configureAndLoad(
            adapterManifests: manifests,
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            locations: [.init(directory: abilities, source: .sourceTree, priority: 20)],
            installedDirectory: nil)
        #expect(report.activated, "the shipped packages did not activate")

        // A Skill may be blocked for other honest reasons (a lane this build
        // does not ship), but never for the one this table exists to answer:
        // an unpublished Perception that Mary in fact concludes on every turn.
        for skill in report.snapshot.skills where skill.availability.readiness == .blocked {
            for reason in skill.availability.reasons {
                for derived in DerivedPerceptions.base.keys where reason.contains(derived.rawValue) {
                    Issue.record(
                        """
                        \(skill.skill.id.rawValue) is blocked over \
                        \(derived.rawValue): \(reason) — but that Perception \
                        is concluded from \(DerivedPerceptions.base[derived]!.rawValue) \
                        on every turn, and the inventory should say so
                        """)
                }
            }
        }
    }
}

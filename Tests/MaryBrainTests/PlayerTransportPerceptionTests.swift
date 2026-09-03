//
//  PlayerTransportPerceptionTests.swift
//  MaryBrainTests
//
//  WHAT: Package-declared perception publish path against shipped packages.
//  OUT:  SchemaSignalRuntime.publishPerception
//

import Foundation
import Testing
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct PlayerTransportPerceptionTests {

    private static let schemaID: PerceptionID = "perception.player-transport"

    /// The shipped registry, joined with the adapter roster the app installs.
    private static func shippedRegistry(
        _ abilities: URL
    ) -> AbilityRuntime.Snapshot? {
        let adapters = MaryAdapterCatalog.adapters()
        let library = AbilityLibrary(fileManager: .default, runtimeVersion: "1.0.0")
        let report = library.configureAndLoad(
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: adapters,
                observers: MaryAdapterCatalog.observers()),
            nativeApplicationProfiles: adapters.map(\.applicationProfile),
            locations: [.init(directory: abilities, source: .sourceTree, priority: 20)],
            installedDirectory: nil)
        return report.activated ? report.snapshot : nil
    }

    /// Byte-for-byte the envelope `MaryRuntime.publishPlayerTransportPerception`
    /// builds, minus the Accessibility read that supplies the sentence. If this
    /// shape stops being accepted, that lane stops publishing — silently, since
    /// it logs and returns rather than trapping.
    private static func envelope(_ summary: String) -> ValueEnvelope {
        ValueEnvelope(
            typeID: "multimedia.now-playing-report",
            value: .string(summary),
            scope: SourceScope(applicationID: "apple-music", processID: 4321),
            provenance: .init(operation: "now_playing"),
            privacy: .private)
    }

    @Test func theMediaSurfaceAdapterMayPublishThePlayerTransport() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let registry = try #require(
            Self.shippedRegistry(abilities), "the shipped packages did not activate")
        #expect(
            registry.perceptionSchema(id: Self.schemaID) != nil,
            "multimedia.mary no longer declares \(Self.schemaID.rawValue)")

        let runtime = SchemaSignalRuntime()
        _ = try runtime.publishPerception(
            schemaID: Self.schemaID,
            value: Self.envelope("Apple Music is playing \"Petrichor\"."),
            adapterID: "media-surface",
            registry: registry)

        let turn = runtime.snapshotForTurn(registry: registry)
        #expect(
            turn.perceptionIDs.contains(Self.schemaID),
            "the published transport did not reach the turn snapshot")
    }

    /// AN UNDECLARED ADAPTER IS REFUSED, which is the guard that makes the
    /// manifest declaration load-bearing rather than decorative. `window-management`
    /// is installed and available and still may not publish this.
    @Test func anAdapterThatDoesNotDeclareItMayNotPublishIt() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let registry = try #require(Self.shippedRegistry(abilities))
        let runtime = SchemaSignalRuntime()
        // THE EXACT REFUSAL, not merely "it threw". `window-management` is
        // installed and available, so a bare throws-check here would also pass
        // if the adapter had simply gone missing from the registry — which is
        // the one way this test could stop testing the guard it names.
        #expect(throws: SchemaSignalRuntimeError.undeclaredPerception(
            "window-management", Self.schemaID)) {
            try runtime.publishPerception(
                schemaID: Self.schemaID,
                value: Self.envelope("borrowed"),
                adapterID: "window-management",
                registry: registry)
        }
    }

    /// THE REASON THE REQUIREMENT BECAME OPTIONAL RATHER THAN BEING DELETED.
    /// Moving it out of `requirements.perceptions` stopped it gating dispatch;
    /// it must still reach execution as evidence, or the move would have thrown
    /// the reading away instead of relaxing the gate.
    @Test func anOptionalPerceptionStillReachesTheSkillThatDeclaredIt() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let registry = try #require(Self.shippedRegistry(abilities))
        let control = try #require(
            registry.skills.first { $0.skill.id == "multimedia.control-playback" },
            "multimedia.control-playback is no longer in the registry")

        // The gate this whole change was about: nothing may be REQUIRED that
        // only a live player can produce.
        #expect(
            !control.skill.requirements.perceptions.contains(Self.schemaID),
            "control-playback requires a Perception again — it will refuse at dispatch")
        #expect(
            control.skill.requirements.optionalPerceptions.contains(Self.schemaID))

        let runtime = SchemaSignalRuntime()
        _ = try runtime.publishPerception(
            schemaID: Self.schemaID,
            value: Self.envelope("Apple Music is paused."),
            adapterID: "media-surface",
            registry: registry)

        let delivered = runtime.snapshotForTurn(registry: registry)
            .perceptions(declaredBy: control.skill)
        #expect(
            delivered.contains { $0.reference.schemaID == Self.schemaID },
            "the transport reading never reached control-playback")
    }
}

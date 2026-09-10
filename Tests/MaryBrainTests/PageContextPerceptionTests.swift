//
//  PageContextPerceptionTests.swift
//  MaryBrainTests
//
//  WHAT: The page-context perception publishes, against the shipped packages.
//  OUT:  SchemaSignalRuntime.publishPerception
//  PIN:  THE TWIN OF PlayerTransportPerceptionTests, and for the same reason: the
//        publisher logs and returns rather than trapping, so a declaration that stopped
//        being accepted would go quiet instead of failing. This is what notices.
//        IT MATTERS MOST TO A BROWSING TURN. Without this perception the roster is
//        arbitrated with no evidence of what page is open, and the browsing skills lose
//        the signal their eligibility reads.
//
import Foundation
import Testing
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct PageContextPerceptionTests {

    private static let schemaID: PerceptionID = "perception.page-context"

    /// The shipped registry, joined with the adapter roster the app installs.
    private static func shippedRegistry(_ abilities: URL) -> AbilityRuntime.Snapshot? {
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

    /// Byte-for-byte the envelope `TurnPerceptionPublisher.publishPageContext` builds,
    /// minus the Accessibility read that supplies the sentence.
    private static func envelope(_ summary: String) -> ValueEnvelope {
        ValueEnvelope(
            typeID: "browsing.page-report",
            value: .string(summary),
            scope: SourceScope(applicationID: "safari", processID: 4321),
            provenance: .init(operation: "current_page"),
            privacy: .private)
    }

    @Test func theWebSurfaceAdapterMayPublishThePageContext() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let registry = try #require(
            Self.shippedRegistry(abilities), "the shipped packages did not activate")
        #expect(
            registry.perceptionSchema(id: Self.schemaID) != nil,
            "browsing.mary no longer declares \(Self.schemaID.rawValue)")

        let runtime = SchemaSignalRuntime()
        _ = try runtime.publishPerception(
            schemaID: Self.schemaID,
            value: Self.envelope("You're on Ski touring - Wikipedia, at wikipedia."),
            adapterID: "web-surface",
            registry: registry)

        let turn = runtime.snapshotForTurn(registry: registry)
        #expect(
            turn.perceptionIDs.contains(Self.schemaID),
            "the published page context did not reach the turn snapshot")
    }

    /// AN UNDECLARED ADAPTER IS REFUSED. `media-surface` is installed, publishes its own
    /// perception happily, and still may not publish this one.
    @Test func anAdapterThatDoesNotDeclareItMayNotPublishIt() throws {
        guard let abilities = InstalledPackages.installed() else { return }
        let registry = try #require(Self.shippedRegistry(abilities))
        let runtime = SchemaSignalRuntime()

        #expect(throws: (any Error).self) {
            _ = try runtime.publishPerception(
                schemaID: Self.schemaID,
                value: Self.envelope("You're somewhere."),
                adapterID: "media-surface",
                registry: registry)
        }
    }

    /// THE SENTENCE IS THE SKILL'S OWN. Perception and Skill must not drift, so the
    /// publisher and `current_page` both speak through `BrowserEngine.spoken`.
    @Test func theSentenceComesFromTheSameHelperTheSkillUses() {
        let reading = WebSurfaceAX.Reading(
            title: "Ski touring - Wikipedia",
            url: "https://en.wikipedia.org/wiki/Ski_touring",
            pageFrame: nil,
            pageFrameSource: "test",
            canGoBack: nil,
            canGoForward: nil,
            tabs: [],
            windowFrame: .zero)
        let spoken = BrowserEngine.spoken(reading, browser: "Safari")
        #expect(spoken.contains("Ski touring - Wikipedia"))
        // The site, never the address.
        #expect(!spoken.contains("https://"))
    }
}

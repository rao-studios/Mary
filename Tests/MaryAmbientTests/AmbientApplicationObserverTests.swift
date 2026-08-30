//
//  AmbientApplicationObserverTests.swift
//  MaryAmbientTests
//
//  WHAT: Observer contract without timers — coalesce, replace, retract, vanish.
//  OUT:  AmbientApplicationObserver
//

import Foundation
import os
import Testing
@testable import MaryAmbient

@Suite struct AmbientApplicationObserverTests {

    private func withRoster<T>(
        _ registrations: [ApplicationRegistration], _ body: () -> T
    ) -> T {
        AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster(registrations), operation: body)
    }

    private func sighted(
        _ id: String, seconds: Int = 30
    ) -> ApplicationRegistration {
        ApplicationRegistration(
            id: id,
            profile: ApplicationProfile(id: id, title: id.capitalized, summary: "Test."),
            bundleIdentifiers: ["com.example.\(id)"],
            worldClass: .workspace,
            perception: .init(
                kind: .workspace, documentOperation: "\(id)_read", pollSeconds: seconds))
    }

    /// Lanes exist exactly for the sighted registrations; a blind one
    /// (no contract) gets none.
    @Test func lanesDeriveFromTheSightedRoster() {
        let store = AmbientContextStore()
        let observer = AmbientApplicationObserver(store: store)
        let blind = ApplicationRegistration(
            id: "blind",
            profile: ApplicationProfile(id: "blind", title: "Blind", summary: "Test."),
            bundleIdentifiers: ["com.example.blind"],
            worldClass: .dataSource)
        withRoster([sighted("sketch"), blind]) { observer.activate() }
        #expect(observer.laneIDsForTesting == ["sketch"])
        observer.deactivate()
        #expect(observer.laneIDsForTesting.isEmpty)
    }

    /// A successful poll replaces the lane's perceived facts; the fresh
    /// window derives from the cadence.
    @Test func aSuccessfulPollReplacesTheLanesFacts() async {
        let store = AmbientContextStore()
        let observer = AmbientApplicationObserver(store: store)
        observer.installReader { id, operation in
            #expect(operation == "sketch_read")
            return [AmbientFact(
                world: .applications, application: id,
                slot: .file, content: "Canvas: 3 layers",
                subject: "Sketch", provenance: .recipeRead,
                registration: .perceived)]
        }
        withRoster([sighted("sketch")]) { observer.activate() }
        observer.requestPoll(registrationID: "sketch")
        try? await Task.sleep(nanoseconds: 100_000_000)

        let facts = store.facts(
            place: AmbientPlace(world: .applications, application: "sketch"))
        #expect(facts.count == 1)
        #expect(facts.first?.content == "Canvas: 3 layers")
        // freshFor is stamped from the cadence: 30s × 1.5.
        #expect(facts.first?.freshFor == 45)
        observer.deactivate()
    }

    /// THE RETRACTION. Three consecutive misses forget the lane's perceived
    /// facts — a stale outline must never stand as live sight — and the lane
    /// keeps its counter so a comeback resets cleanly.
    @Test func threeMissesRetractTheLane() async {
        let store = AmbientContextStore()
        let observer = AmbientApplicationObserver(store: store)
        let succeed = OSAllocatedUnfairLock(initialState: true)
        observer.installReader { id, _ in
            succeed.withLock { $0 }
                ? [AmbientFact(
                    world: .applications, application: id,
                    slot: .file, content: "live",
                    subject: "Sketch", provenance: .recipeRead,
                    registration: .perceived)]
                : nil
        }
        withRoster([sighted("sketch")]) { observer.activate() }

        observer.requestPoll(registrationID: "sketch")
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(!store.facts(place: AmbientPlace(world: .applications, application: "sketch")).isEmpty)

        succeed.withLock { $0 = false }
        for _ in 0..<AmbientApplicationObserver.missBudget {
            observer.requestPoll(registrationID: "sketch")
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        #expect(observer.missesForTesting("sketch") == AmbientApplicationObserver.missBudget)
        #expect(store.facts(place: AmbientPlace(world: .applications, application: "sketch")).isEmpty,
                "three misses must retract the lane's perceived facts")

        // The comeback: one success resets the counter and restores sight.
        succeed.withLock { $0 = true }
        observer.requestPoll(registrationID: "sketch")
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(observer.missesForTesting("sketch") == 0)
        #expect(!store.facts(place: AmbientPlace(world: .applications, application: "sketch")).isEmpty)
        observer.deactivate()
    }

    /// A registration that vanishes from the roster loses its lane AND its
    /// facts on the next activate — sight is maintained or it is gone.
    @Test func aVanishedRegistrationLosesItsLaneAndFacts() async {
        let store = AmbientContextStore()
        let observer = AmbientApplicationObserver(store: store)
        observer.installReader { id, _ in
            [AmbientFact(
                world: .applications, application: id,
                slot: .file, content: "live", subject: id,
                provenance: .recipeRead, registration: .perceived)]
        }
        withRoster([sighted("sketch")]) { observer.activate() }
        observer.requestPoll(registrationID: "sketch")
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(!store.facts(place: AmbientPlace(world: .applications, application: "sketch")).isEmpty)

        withRoster([]) { observer.activate() }
        #expect(observer.laneIDsForTesting.isEmpty)
        #expect(store.facts(place: AmbientPlace(world: .applications, application: "sketch")).isEmpty)
    }

    /// No reader installed → silent timers, no claims, no crash.
    @Test func noReaderMeansNoClaims() async {
        let store = AmbientContextStore()
        let observer = AmbientApplicationObserver(store: store)
        withRoster([sighted("sketch")]) { observer.activate() }
        observer.requestPoll(registrationID: "sketch")
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.facts(place: AmbientPlace(world: .applications, application: "sketch")).isEmpty)
        observer.deactivate()
    }
}

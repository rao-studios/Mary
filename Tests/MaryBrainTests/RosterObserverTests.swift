//
//  RosterObserverTests.swift
//  MaryBrainTests
//
//  WHAT: The roster a watcher is shown is the roster the turn actually projected.
//  OUT:  MaryBrain.setRosterProjectionObserver
//  PIN:  THE BUG THIS PINS WAS INVISIBLE, WHICH IS WHY IT NEEDS A TEST. Reading
//        `AbilityRuntime.abilityRosterTrace` after a turn re-arbitrates on demand,
//        outside the turn's frozen signals and task-locals — so a bench showed a
//        plausible roster that no turn had ever used, and a confidence-lane dispatch
//        (which returns before the second projection) showed one that could not have
//        existed. The observer fires INSIDE, and these tests hold it there.
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation
import MaryVoice
@testable import MaryPlugin
@testable import MaryBrain

@Suite(.serialized) struct RosterObserverTests {

    /// FIRED DURING THE TURN, WITH WHAT THE TURN HELD. The stub's trace is distinctive,
    /// so a watcher that re-derived its own would be handed something else.
    @Test func theObserverIsHandedTheTurnsOwnProjection() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.rosterTrace = Self.trace(reason: "this turn's arbitration")
        let brain = MaryBrain(
            engine: BrainFakes.ScriptedEngine(rounds: [.init(text: "All right.")]),
            dispatcher: dispatcher)
        let seen = Box()
        await brain.setRosterProjectionObserver { seen.append($0) }

        _ = try await Self.collect(brain, "what is on my screen")

        let traces = seen.value()
        #expect(!traces.isEmpty, "no roster ever reached the watcher")
        #expect(traces.allSatisfy {
            $0.decisions.first?.reason == "this turn's arbitration"
        })
    }

    /// AND IT ARRIVES BEFORE THE TURN SPEAKS — which is the whole claim. The routed
    /// projection happens ahead of every lane, so a watcher knows what was on offer
    /// while the answer is still being decided, not after it has been given.
    ///
    /// PIN: BEFORE THE FIRST TOKEN, NOT BEFORE THE FIRST EVENT. The turn yields its
    /// opening state events before it routes anything — measured, not assumed — and a
    /// test that demanded otherwise would be pinning the order of the lifecycle rather
    /// than the observer.
    @Test func theRosterArrivesBeforeTheTurnSpeaks() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.rosterTrace = Self.trace(reason: "early")
        let brain = MaryBrain(
            engine: BrainFakes.ScriptedEngine(rounds: [.init(text: "All right.")]),
            dispatcher: dispatcher)
        let seen = Box()
        await brain.setRosterProjectionObserver { seen.append($0) }

        var sawRosterFirst: Bool?
        var spoke = false
        for try await event in brain.respond(to: "what is on my screen") {
            guard case .token = event else { continue }
            spoke = true
            if sawRosterFirst == nil { sawRosterFirst = !seen.value().isEmpty }
        }
        #expect(spoke, "the turn never spoke, so the ordering was never tested")
        #expect(sawRosterFirst == true)
    }

    /// A WATCHER THAT LEAVES STOPS BEING TOLD. The closure is retained by the brain, so
    /// a bench that closed without clearing it would keep a dead view alive.
    @Test func clearingTheObserverStopsIt() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        let brain = MaryBrain(
            engine: BrainFakes.ScriptedEngine(rounds: [.init(text: "One."), .init(text: "Two.")]),
            dispatcher: dispatcher)
        let seen = Box()
        await brain.setRosterProjectionObserver { seen.append($0) }
        _ = try await Self.collect(brain, "what is on my screen")
        let afterFirst = seen.value().count
        #expect(afterFirst > 0)

        await brain.setRosterProjectionObserver(nil)
        _ = try await Self.collect(brain, "and now")

        #expect(seen.value().count == afterFirst)
    }

    // MARK: - Support

    /// A trace with one decision whose reason is the fingerprint the tests look for.
    private static func trace(reason: String) -> AbilityRosterTrace {
        AbilityRosterTrace(decisions: [
            AbilityRosterDecision(
                key: AbilityRosterSkillKey(
                    packageID: PackageID("fixture"),
                    abilityID: AbilityID("fixture.ability"),
                    skillID: SkillID("fixture.skill")),
                reference: fixtureAbilityReference("probe"),
                conflictGroup: nil,
                policy: .highestEvidence,
                disposition: .selected,
                evidence: AbilityRoutingEvidenceScore(total: 1),
                reason: reason),
        ])
    }

    /// Traces arrive on whatever task the turn is running; the suite reads them from
    /// another. One lock, for the same reason `BrainFakes` has one.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var traces: [AbilityRosterTrace] = []
        func append(_ trace: AbilityRosterTrace) {
            lock.lock(); defer { lock.unlock() }
            traces.append(trace)
        }
        func value() -> [AbilityRosterTrace] {
            lock.lock(); defer { lock.unlock() }
            return traces
        }
    }

    private static func collect(
        _ brain: MaryBrain, _ text: String
    ) async throws -> [BrainEvent] {
        var events: [BrainEvent] = []
        for try await event in brain.respond(to: text) { events.append(event) }
        return events
    }
}

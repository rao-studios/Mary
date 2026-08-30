//
//  SkillTimeoutAndQueueTests.swift
//  MaryBrainTests
//
//  Ordinary Skill runs take the 1…10 s cap; named build/test jobs do not.
//  Life treats in-flight Skills and detached routines as busy. A third
//  detach cancels the oldest lane rather than stacking the engine gate.
//

import Foundation
import Testing
import MaryVoice
@testable import MaryBrain

@Suite struct SkillTimeoutAndQueueTests {

    @Test func ordinaryTimeoutClampsToOneThroughTen() {
        #expect(AbilityRuntime.clampedOrdinarySkillTimeout(0) == 1)
        #expect(AbilityRuntime.clampedOrdinarySkillTimeout(1) == 1)
        #expect(AbilityRuntime.clampedOrdinarySkillTimeout(2) == 2)
        #expect(AbilityRuntime.clampedOrdinarySkillTimeout(10) == 10)
        #expect(AbilityRuntime.clampedOrdinarySkillTimeout(11) == 10)
        #expect(AbilityRuntime.clampedOrdinarySkillTimeout(-4) == 1)
    }

    @Test func ordinarySkillTakesTheUserCap() {
        #expect(
            AbilityRuntime.effectiveBudget(
                bindingName: "type_text",
                declared: AbilityRuntime.defaultSkillBudget,
                userCap: 2)
            == 2)
    }

    @Test func namedLongJobsKeepTheirCeiling() {
        #expect(
            AbilityRuntime.effectiveBudget(
                bindingName: "run_tests", declared: 330, userCap: 2)
            == 330)
        #expect(
            AbilityRuntime.effectiveBudget(
                bindingName: "build_check", declared: 330, userCap: 2)
            == 330)
        #expect(
            AbilityRuntime.effectiveBudget(
                bindingName: "complete_coding_change", declared: 280, userCap: 2)
            == 280)
        #expect(
            AbilityRuntime.effectiveBudget(
                bindingName: "run_shortcut", declared: 150, userCap: 2)
            == 150)
        #expect(
            AbilityRuntime.effectiveBudget(
                bindingName: "zip_folder", declared: 150, userCap: 2)
            == 150)
    }

    @Test func ordinaryWorkflowTakesTheUserCap() {
        #expect(
            AbilityRuntime.effectiveWorkflowBudget(
                invocationName: "type_text",
                packageTimeout: 30,
                policyCap: 600,
                userCap: 2)
            == 2)
    }

    @Test func namedWorkflowKeepsPackageTimeout() {
        #expect(
            AbilityRuntime.effectiveWorkflowBudget(
                invocationName: "run_tests",
                packageTimeout: 330,
                policyCap: 600,
                userCap: 2)
            == 330)
    }

    @Test func detachedCapCancelsOldestWhenAThirdWouldJoin() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let d = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let e = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

        #expect(
            MaryBrain.idsToCancelForDetachedCap(
                existing: [(id: a, spawnedUptime: 1)], cap: 2)
            == [])
        #expect(
            MaryBrain.idsToCancelForDetachedCap(
                existing: [
                    (id: a, spawnedUptime: 10),
                    (id: b, spawnedUptime: 20),
                ],
                cap: 2)
            == [a])
        #expect(
            MaryBrain.idsToCancelForDetachedCap(
                existing: [
                    (id: a, spawnedUptime: 10),
                    (id: b, spawnedUptime: 20),
                    (id: c, spawnedUptime: 30),
                    (id: d, spawnedUptime: 40),
                    (id: e, spawnedUptime: 50),
                ],
                cap: 2)
            == [a, b, c, d])
    }

    @Test func isBusyWhileDispatcherHasInFlightRuns() async {
        let dispatcher = InFlightDispatcher(running: ["run-1"])
        let brain = MaryBrain(engine: BrainFakes.ScriptedEngine(rounds: []), dispatcher: dispatcher)
        #expect(await brain.isBusy)
        dispatcher.runningRunIDs = []
        #expect(await brain.isBusy == false)
    }

    @Test func isBusyWhileDetachedRoutineRuns() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [
            .init(events: [.token("On it.")]),
        ])
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [
                ModelSkillInvocation(
                    id: UUID().uuidString, name: "probe", argumentsJSON: "{}"),
            ]),
        ])
        let dispatcher = ParkingDispatcher()
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)
        await brain.setActionJoinGraceForTesting(1_000_000)
        await brain.setLaneJoinGraceForTesting(1_000_000)

        let turn = Task {
            do {
                for try await _ in brain.respond(to: "run the slow probe") {}
            } catch {}
        }
        await dispatcher.awaitEntered()
        var detached = false
        for _ in 0..<200 {
            if await brain.hasOpenTurn == false, await brain.activeRoutines.isEmpty == false {
                detached = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(detached, "lane should detach while the Skill is still parked")
        #expect(await brain.isBusy)
        #expect(await brain.hasOpenTurn == false)

        dispatcher.release()
        _ = await turn.value
        await brain.cancelRoutinesForTesting()
        #expect(await brain.isBusy == false)
    }

    final class InFlightDispatcher: AbilityDispatching, @unchecked Sendable {
        var runningRunIDs: Set<String>
        var schemas: [ModelSkillSchema] { [] }

        init(running: Set<String>) {
            runningRunIDs = running
        }

        func dispatch(
            name: String, argumentsJSON: String, runID: String?
        ) async -> SkillOutcome {
            SkillOutcome(ok: true, summary: "ok")
        }
    }

    final class ParkingDispatcher: AbilityDispatching, @unchecked Sendable {
        private let entered = ArrivalSignal()
        private let released = ArrivalSignal()

        var schemas: [ModelSkillSchema] {
            [ModelSkillSchema(name: "probe", description: "", parameters: [])]
        }

        func awaitEntered() async { await entered.wait(until: 1) }
        func release() { released.advance() }

        func dispatch(
            name: String, argumentsJSON: String, runID: String?
        ) async -> SkillOutcome {
            entered.advance()
            await released.wait(until: 1)
            return SkillOutcome(ok: true, summary: "ok")
        }
    }
}

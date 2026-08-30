//
//  CancelRunTests.swift
//  MaryBrainTests
//
//  WHAT: One named call can be cancelled without stopping every detached routine.
//  OUT:  AbilityRuntime cancel handle
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct CancelRunTests {

    private struct ScriptedAdapter: MaryAdapter {
        let name: String
        let summary = "A fixture."
        let bindings: [SkillBinding]
        var skillBindings: [SkillBinding] { bindings }
    }

    /// A gate the test opens when it is ready for the binding to finish.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var entered = false
        func enter() {
            lock.lock(); entered = true; lock.unlock()
        }
        var hasEntered: Bool {
            lock.lock(); defer { lock.unlock() }
            return entered
        }
        func release() {
            lock.lock(); open = true; lock.unlock()
        }
        var isOpen: Bool {
            lock.lock(); defer { lock.unlock() }
            return open
        }
    }

    private func runtime(_ adapters: [any MaryAdapter], log: AbilityExecutionLog)
        -> AbilityRuntime {
        AbilityRuntime(
            plugins: adapters,
            executionLog: log,
            behavior: nil,
            ambient: AmbientContextStore(),
            passages: PassageRegistry(),
            containers: ContainerRegistry(),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
    }

    /// A binding that parks until the test lets it go, and reports whether it
    /// noticed cancellation — so the test can tell "the Task was cancelled"
    /// apart from "the work simply finished".
    private func slowAdapter(_ latch: Latch) -> any MaryAdapter {
        ScriptedAdapter(name: "scripted", bindings: [
            SkillBinding(
                name: "dawdle",
                description: "A fixture that takes its time.",
                parameters: [],
                access: .read,
                backing: .native { _, _ in
                    latch.enter()
                    while !latch.isOpen, !Task.isCancelled {
                        await Task.yield()
                    }
                    return SkillOutcome(
                        ok: true,
                        summary: Task.isCancelled ? "noticed" : "ran to completion")
                }),
        ])
    }

    @Test func aStoppedCallSettlesAsStoppedRatherThanAsWhateverItReturned() async {
        let latch = Latch()
        let log = AbilityExecutionLog()
        let runtime = runtime([slowAdapter(latch)], log: log)

        let dispatch = Task {
            await runtime.dispatch(
                name: "dawdle", argumentsJSON: "{}", runID: "run-1")
        }
        while !latch.hasEntered { await Task.yield() }
        // The id a chip shows is the id a Stop button sends.
        #expect(runtime.runningRunIDs.contains("run-1"))
        runtime.cancelRun(id: "run-1")

        let outcome = await dispatch.value
        // NOT "completed", and not a failure that blames the application: the
        // person stopped it, and that is what the record has to say.
        #expect(outcome.status == .cancelled)
        #expect(!outcome.ok)

        let record = log.entries().first { $0.id == "run-1" }
        #expect(record?.disposition == .cancelled)
    }

    /// The registry holds only calls that are genuinely still running, so a
    /// Stop can never be offered for something already settled.
    @Test func theRegistryEmptiesWhenTheCallSettles() async {
        let latch = Latch()
        let runtime = runtime([slowAdapter(latch)], log: AbilityExecutionLog())
        #expect(runtime.runningRunIDs.isEmpty)

        let dispatch = Task {
            await runtime.dispatch(
                name: "dawdle", argumentsJSON: "{}", runID: "run-2")
        }
        while !latch.hasEntered { await Task.yield() }
        #expect(runtime.runningRunIDs == ["run-2"])

        latch.release()
        _ = await dispatch.value
        #expect(runtime.runningRunIDs.isEmpty)
    }

    /// A stop that arrives after the call has settled is a race a person can
    /// lose honestly — it must not crash, and it must not rewrite the record.
    @Test func stoppingAnAlreadySettledCallIsANoOp() async {
        let latch = Latch()
        let log = AbilityExecutionLog()
        let runtime = runtime([slowAdapter(latch)], log: log)
        latch.release()

        let outcome = await runtime.dispatch(
            name: "dawdle", argumentsJSON: "{}", runID: "run-3")
        #expect(outcome.ok)

        runtime.cancelRun(id: "run-3")
        runtime.cancelRun(id: "never-existed")
        #expect(log.entries().first { $0.id == "run-3" }?.disposition == .succeeded)
    }

    /// The run id is the CALLER'S — the wire id a chip is keyed by — so the
    /// record a person taps and the call they can stop are the same thing.
    /// A caller with no id still gets a record, under a minted one.
    @Test func theRecordCarriesTheCallersOwnRunID() async {
        let latch = Latch()
        latch.release()
        let log = AbilityExecutionLog()
        let runtime = runtime([slowAdapter(latch)], log: log)

        _ = await runtime.dispatch(
            name: "dawdle", argumentsJSON: "{}", runID: "wire-42")
        #expect(log.entries().contains { $0.id == "wire-42" })

        _ = await runtime.dispatch(name: "dawdle", argumentsJSON: "{}")
        #expect(log.entries().count == 2)
        #expect(log.entries().allSatisfy { !$0.id.isEmpty })
    }
}

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryAdapters
@testable import MaryAmbient

/// The generic destructive-confirmation flow: pending actions are held, not
/// executed, until the user's spoken go-ahead.
@Suite struct ConfirmationFlowTests {

    final class Recorder: @unchecked Sendable {
        var executions: [[String: String]] = []
    }

    private func dangerousRecipe(_ recorder: Recorder) -> SkillBinding {
        SkillBinding(
            name: "wipe_thing",
            description: "test",
            parameters: [.init(name: "target", type: "string", description: "", required: true)],
            access: .write,
            backing: .native { arguments, _ in
                recorder.executions.append(arguments)
                return SkillOutcome(ok: true, summary: "Wiped \(arguments["target"] ?? "?").")
            },
            confirmationPreview: { arguments, _ in
                "This will wipe \(arguments["target"] ?? "?"). Should I?"
            }
        )
    }

    private func makeRegistry(recorder: Recorder) -> AbilityRuntime {
        AbilityRuntime(plugins: [], standalone: [dangerousRecipe(recorder)]) {
            AbilityExecutionContext(projects: [:])
        }
    }

    @Test func confirmableDispatchStoresWithoutExecuting() async {
        let recorder = Recorder()
        let registry = makeRegistry(recorder: recorder)
        registry.beginTurn()

        let outcome = await registry.dispatch(name: "wipe_thing", argumentsJSON: #"{"target": "x"}"#)
        #expect(outcome.summary.hasPrefix("CONFIRM:"))
        #expect(outcome.summary.contains("This will wipe x"))
        #expect(recorder.executions.isEmpty)
    }

    @Test func builtInsAppearOnlyWhilePending() async {
        let recorder = Recorder()
        let registry = makeRegistry(recorder: recorder)
        registry.beginTurn()

        #expect(!registry.schemas.map(\.name).contains(AbilityRuntime.confirmSkillName))
        _ = await registry.dispatch(name: "wipe_thing", argumentsJSON: #"{"target": "x"}"#)
        let names = registry.schemas.map(\.name)
        #expect(names.contains(AbilityRuntime.confirmSkillName))
        #expect(names.contains(AbilityRuntime.cancelSkillName))
    }

    @Test func confirmExecutesStoredArguments() async {
        let recorder = Recorder()
        let registry = makeRegistry(recorder: recorder)
        registry.beginTurn()
        // Argument arrives under a drifted name; reconciliation stores the fixed form.
        let parked = await registry.dispatch(
            name: "wipe_thing", argumentsJSON: #"{"target_name": "x"}"#)

        registry.beginTurn()  // the user's "yes" turn
        let outcome = await registry.dispatch(name: AbilityRuntime.confirmSkillName, argumentsJSON: "{}")
        #expect(outcome.ok)
        #expect(outcome.summary == "Wiped x.")
        #expect(recorder.executions == [["target_name": "x", "target": "x"]])
        #expect(parked.skillReference?.invocationName == "wipe_thing")
        #expect(outcome.skillReference == parked.skillReference,
                "confirmation replays the frozen package identity from the originating turn")
    }

    @Test func cancelDiscards() async {
        let recorder = Recorder()
        let registry = makeRegistry(recorder: recorder)
        registry.beginTurn()
        _ = await registry.dispatch(name: "wipe_thing", argumentsJSON: #"{"target": "x"}"#)

        let cancelled = await registry.dispatch(name: AbilityRuntime.cancelSkillName, argumentsJSON: "{}")
        #expect(cancelled.summary.contains("cancelled"))
        let confirm = await registry.dispatch(name: AbilityRuntime.confirmSkillName, argumentsJSON: "{}")
        #expect(!confirm.ok)
        #expect(recorder.executions.isEmpty)
    }

    @Test func latestConfirmableWins() async {
        let recorder = Recorder()
        let registry = makeRegistry(recorder: recorder)
        registry.beginTurn()
        _ = await registry.dispatch(name: "wipe_thing", argumentsJSON: #"{"target": "first"}"#)
        let firstID = registry.pendingSkillConfirmationID
        _ = await registry.dispatch(name: "wipe_thing", argumentsJSON: #"{"target": "second"}"#)
        let secondID = registry.pendingSkillConfirmationID

        #expect(firstID != nil)
        #expect(secondID != nil)
        #expect(secondID != firstID, "a replacement is a newly parked action")

        let outcome = await registry.dispatch(name: AbilityRuntime.confirmSkillName, argumentsJSON: "{}")
        #expect(outcome.summary == "Wiped second.")
        #expect(recorder.executions.count == 1)
    }

    @Test func pendingExpiresAfterTwoFullTurns() async {
        let recorder = Recorder()
        let registry = makeRegistry(recorder: recorder)
        registry.beginTurn()
        _ = await registry.dispatch(name: "wipe_thing", argumentsJSON: #"{"target": "x"}"#)
        registry.beginTurn()
        registry.beginTurn()

        let outcome = await registry.dispatch(name: AbilityRuntime.confirmSkillName, argumentsJSON: "{}")
        #expect(!outcome.ok)
        #expect(recorder.executions.isEmpty)
    }

    @Test func ttlExpiry() {
        let store = PendingSkillStore(timeToLive: 60)
        store.beginTurn()
        let past = Date(timeIntervalSinceNow: -120)
        store.set(
            skillName: "wipe_thing",
            arguments: [:],
            preview: "?",
            context: AbilityExecutionContext(projects: [:]),
            reference: fixtureAbilityReference("wipe_thing"),
            now: past)
        #expect(store.take() == nil)
    }

    @Test func confirmWithNothingPendingIsGraceful() async {
        let registry = makeRegistry(recorder: Recorder())
        registry.beginTurn()
        let outcome = await registry.dispatch(name: AbilityRuntime.confirmSkillName, argumentsJSON: "{}")
        #expect(!outcome.ok)
    }

    @Test func fuzzyMatchingNeverEatsBuiltIns() async {
        let recipe = SkillBinding(
            name: "confirm_order", description: "test", access: .read,
            backing: .native { _, _ in SkillOutcome(ok: true, summary: "ordered") }
        )
        let registry = AbilityRuntime(plugins: [], standalone: [recipe]) {
            AbilityExecutionContext(projects: [:])
        }
        registry.beginTurn()
        let outcome = await registry.dispatch(name: AbilityRuntime.confirmSkillName, argumentsJSON: "{}")
        #expect(outcome.summary != "ordered")
    }
}

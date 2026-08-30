//
//  HistoryIntegrityTests.swift
//  MaryBrainTests
//
//  WHAT: Seer wire never sees two consecutive same-role messages.
//  OUT:  History alternation under supersede / merge / trim
//

import MaryVoice
import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

@Suite struct HistoryIntegrityTests {

    // MARK: - Scripted collaborators (suite-local copies, DualLaneTests style)

    final class ScriptedSeer: SeerChatProviding, @unchecked Sendable {
        struct Script {
            var events: [SeerChatEvent] = []
            var hangAtEnd = false
        }

        private let lock = NSLock()
        var ready = true
        private var scripts: [Script]
        private(set) var calls: [[SeerChatMessage]] = []
        /// Advanced once per `stream()` — "Lane A of the Nth turn is running".
        /// The stated arrival that replaces "sleep 150 ms and hope turn 1 is
        /// mid-flight" (SupersedeTests' ScriptedSeer has the same signal).
        private let requests = ArrivalSignal()

        init(scripts: [Script]) {
            self.scripts = scripts
        }

        /// Lock-guarded value copy — the only way a test body may read
        /// `calls`: a detached routine can still be appending when an
        /// assertion runs, and an unguarded read of live storage tears count
        /// against buffer (the suite's old signal-5 crash).
        func callsSnapshot() -> [[SeerChatMessage]] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func isReady() async -> Bool { ready }
        func ownerID() async -> String? { "owner-test" }

        func stream(
            messages: [SeerChatMessage], instructions: String?
        ) -> AsyncThrowingStream<SeerChatEvent, Error> {
            lock.lock()
            calls.append(messages)
            let script = scripts.isEmpty ? Script() : scripts.removeFirst()
            lock.unlock()
            let stream = AsyncThrowingStream<SeerChatEvent, Error> { continuation in
                for event in script.events { continuation.yield(event) }
                if !script.hangAtEnd { continuation.finish() }
                continuation.onTermination = { _ in }
            }
            // AFTER the stream is built, so a waiter that wakes on this
            // signal finds the turn genuinely in flight.
            requests.advance()
            return stream
        }

        /// Suspends until Lane A of the `count`-th turn has asked for its stream.
        func awaitStreamRequest(_ count: Int) async { await requests.wait(until: count) }
    }

    final class ScriptedEngine: InferenceEngine, @unchecked Sendable {
        struct Round {
            var text: String = ""
            var calls: [ModelSkillInvocation] = []
        }

        let displayName = "scripted"
        private let lock = NSLock()
        private var rounds: [Round]
        private(set) var requests: [[BrainTurn.Role]] = []

        init(rounds: [Round]) {
            self.rounds = rounds
        }

        /// Lock-guarded value copy — see `ScriptedSeer.callsSnapshot`.
        func requestsSnapshot() -> [[BrainTurn.Role]] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        func warmup() async throws {}

        func stream(system: String, history: [BrainTurn], skills: [ModelSkillSchema]) -> AsyncThrowingStream<EngineEvent, Error> {
            lock.lock()
            requests.append(history.map(\.role))
            let round = rounds.isEmpty ? Round() : rounds.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                if !round.text.isEmpty { continuation.yield(.text(round.text)) }
                for call in round.calls { continuation.yield(.skillInvocation(call)) }
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    final class SlowDispatcher: AbilityDispatching, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var dispatched: [String] = []
        var results: [String: String] = [:]
        var delayNanoseconds: UInt64 = 0
        var failingTools: Set<String> = []

        var schemas: [ModelSkillSchema] {
            [ModelSkillSchema(name: "probe", description: "", parameters: [])]
        }

        var hasPendingSkillConfirmation: Bool { false }
        func beginTurn() {}

        /// Lock-guarded value copy — see `ScriptedSeer.callsSnapshot`.
        func dispatchedSnapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return dispatched
        }

        func dispatch(name: String, argumentsJSON: String, runID: String? = nil) async -> SkillOutcome {
            lock.lock(); dispatched.append(name); lock.unlock()
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            lock.lock()
            let summary = results[name] ?? "ok"
            let ok = !failingTools.contains(name)
            lock.unlock()
            return SkillOutcome(ok: ok, summary: summary)
        }
    }

    private func call(_ name: String) -> ModelSkillInvocation {
        ModelSkillInvocation(id: UUID().uuidString, name: name, argumentsJSON: "{}")
    }

    private func collect(_ stream: AsyncThrowingStream<BrainEvent, Error>) async throws -> [BrainEvent] {
        var events: [BrainEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// Waits for the routine's terminal proactive event (or times out) so a
    /// regression fails instead of hanging the suite.
    private func awaitSettled(
        _ stream: AsyncStream<ProactiveEvent>, timeoutSeconds: Double = 6
    ) async {
        _ = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    switch event {
                    case .followUpCompleted, .routineCancelled, .routineSettled: return true
                    default: break
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - The invariant

    private func expectAlternation(_ messages: [SeerChatMessage]) {
        for (a, b) in zip(messages, messages.dropFirst()) {
            #expect(a.role != b.role, "consecutive \(a.role) breaks Seer-wire alternation")
        }
    }

    /// The direct H-A pin: pre-fix, an overlapping plain respond left the
    /// hung turn's user message in history with no assistant — [user, user].
    @Test func alternationHoldsAfterOverlapSupersede() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Thinking about one")], hangAtEnd: true),
            .init(events: [.token("Two it is.")]),
        ])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP"), .init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        let firstTurn = Task { try? await collect(brain.respond(to: "one")) }
        // STATED, NOT SLEPT: turn 1 has asked Seer for its (hanging) stream,
        // so its exchange is open and the overlap below provably supersedes
        // it. The 150 ms sleep this replaces lost about one full-suite run in
        // five — turn 2 landed BEFORE turn 1 had started, completed with
        // nothing to supersede, and turn 1 then hung on its never-finishing
        // stream with nothing left to cancel it: `firstTurn.value` parked the
        // whole test process forever at 0% CPU.
        await seer.awaitStreamRequest(1)
        _ = try await collect(brain.respond(to: "two"))
        _ = await firstTurn.value
        try await Task.sleep(nanoseconds: 100_000_000)   // stale unwind window

        let spoken = await brain.spokenMessagesForTesting()
        expectAlternation(spoken)
        #expect(spoken.map(\.role) == ["user", "assistant"], "\(spoken.map(\.content))")
    }

    @Test func alternationHoldsAfterDetachAndMerge() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("On it.")]),             // turn 1 → routine
            .init(events: [.token("Meanwhile, hi!")]),     // intervening turn
            .init(events: [.token("It failed, sorry.")]),  // follow-up pass
        ])
        let engine = ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),
            .init(text: "NOOP"),
        ])
        let dispatcher = SlowDispatcher()
        dispatcher.delayNanoseconds = 900_000_000
        dispatcher.results["probe"] = "no such probe"
        dispatcher.failingTools = ["probe"]   // a failure speaks — and merges
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let proactiveStream = brain.proactiveEvents()
        let settle = Task { await awaitSettled(proactiveStream) }
        _ = try await collect(brain.respond(to: "run the slow probe"))
        _ = try await collect(brain.respond(to: "hello while busy"))
        _ = await settle.value

        let spoken = await brain.spokenMessagesForTesting()
        expectAlternation(spoken)
        #expect(spoken.contains { $0.role == "assistant" && $0.content.contains("It failed, sorry.") },
                "the merge landed on the origin: \(spoken.map(\.content))")
    }

    @Test func alternationHoldsAfterTrimWithLiveRoutine() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("On it.")]),
            .init(events: [.token("Two.")]),
            .init(events: [.token("Three.")]),
            .init(events: [.token("It broke, sorry.")]),   // follow-up pass
        ])
        let engine = ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),
            .init(text: "NOOP"),
            .init(text: "NOOP"),
        ])
        let dispatcher = SlowDispatcher()
        dispatcher.delayNanoseconds = 1_500_000_000
        dispatcher.results["probe"] = "the probe broke"
        dispatcher.failingTools = ["probe"]
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)
        await brain.setHistoryLimit(4)   // the floor — trims the origin fastest

        let proactiveStream = brain.proactiveEvents()
        let settle = Task { await awaitSettled(proactiveStream) }
        _ = try await collect(brain.respond(to: "run the slow probe"))
        _ = try await collect(brain.respond(to: "second topic"))
        _ = try await collect(brain.respond(to: "third topic"))   // origin trims out
        _ = await settle.value

        let spoken = await brain.spokenMessagesForTesting()
        expectAlternation(spoken)
        // The dropped-merge pin: the follow-up text appears NOWHERE.
        #expect(!spoken.contains { $0.content.contains("It broke, sorry.") },
                "\(spoken.map(\.content))")
    }

    /// Supersede racing finishRoutine: the routine's merge lands (or drops)
    /// while an overlap removes ANOTHER turn's exchange — actor-serialized,
    /// so either order must leave alternation intact.
    @Test func alternationHoldsWhenSupersedeRacesFinishRoutine() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("On it.")]),                    // turn 1 → routine
            .init(events: [.token("Hanging")], hangAtEnd: true),  // turn 2 hangs
            .init(events: [.token("A.")]),                        // turn 3 / follow-up (racy order)
            .init(events: [.token("B.")]),
        ])
        let engine = ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),
            .init(text: "NOOP"),
            .init(text: "NOOP"),
        ])
        let dispatcher = SlowDispatcher()
        dispatcher.delayNanoseconds = 600_000_000
        dispatcher.results["probe"] = "no such probe"
        dispatcher.failingTools = ["probe"]   // failing → the merge is due at settle
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        // Turn 1 detaches its slow failing lane at the 250ms grace.
        _ = try await collect(brain.respond(to: "run the slow probe"))
        // Turn 2 hangs mid-stream; turn 3 overlaps it right as the routine's
        // 600ms dispatch settles — the merge and the supersede land within
        // ~100ms of each other, in either order.
        let secondTurn = Task { try? await collect(brain.respond(to: "hanging question")) }
        try await Task.sleep(nanoseconds: 250_000_000)
        _ = try await collect(brain.respond(to: "actually answer this"))
        _ = await secondTurn.value
        try await Task.sleep(nanoseconds: 1_200_000_000)   // both storms settle

        let spoken = await brain.spokenMessagesForTesting()
        expectAlternation(spoken)
        let active = await brain.isRoutineActive
        #expect(!active, "the routine settled through the race")
    }
}

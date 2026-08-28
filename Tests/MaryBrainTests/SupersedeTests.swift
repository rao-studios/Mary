//
//  SupersedeTests.swift
//  MaryBrainTests
//
//  The amend flow's brain half: respondSuperseding cancels the in-flight
//  turn, removes its exchange wholesale (user turn + tool pairs + partials),
//  and runs the amended query on a clean slate — while the epoch guard drops
//  any late writes from the superseded turn. Subprocess kill-on-cancel is
//  covered here too.
//

import MaryVoice
import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

// `ArrivalSignal` — the counted arrival primitive this file introduced —
// now lives in BrainTestSupport.swift, cancellation-aware, for the whole
// target.

@Suite struct SupersedeTests {

    // MARK: - Scripted collaborators (suite-local copies, DualLaneTests style)

    final class ScriptedSeer: SeerChatProviding, @unchecked Sendable {
        struct Script {
            var events: [SeerChatEvent] = []
            var hangAtEnd = false
            /// Yield the events, then hold Lane A OPEN until the test calls
            /// `endHeldStream()`. `hangAtEnd` is the same idea with no release.
            ///
            /// DO NOT read "Lane A has ended" as "the turn is now inside its
            /// join grace" — that inference was tried here and is false, which
            /// is why it currently has no callers. `runTurn` still has to drain
            /// the stream and clear the barge-in check (`if Task.isCancelled`)
            /// before it reaches `laneFinished`, and that takes several actor
            /// turns, not one. A test that supersedes on this signal lands on
            /// the barge-in side, no routine is ever born, and it fails with a
            /// timeout for a scenario that never happened. Use an ACTION turn
            /// (no Lane A at all) plus `setActionJoinGraceForTesting` when you
            /// need to be provably mid-grace — see
            /// `overlapDuringGraceDetachesRoutineAsSuperseded`.
            var holdOpen = false
        }

        private let lock = NSLock()
        var ready = true
        private var scripts: [Script]
        private(set) var calls: [[SeerChatMessage]] = []
        /// Advanced once per `stream()` — "Lane A of the Nth turn is running".
        private let requests = ArrivalSignal()
        private var heldStream: AsyncThrowingStream<SeerChatEvent, Error>.Continuation?

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
                if script.holdOpen {
                    self.lock.lock()
                    self.heldStream = continuation
                    self.lock.unlock()
                } else if !script.hangAtEnd {
                    continuation.finish()
                }
                continuation.onTermination = { _ in }
            }
            // AFTER the stream is built, so a waiter that wakes on this signal
            // always finds the held continuation installed.
            requests.advance()
            return stream
        }

        /// Suspends until Lane A of the `count`-th turn has asked for its
        /// stream — the fact the sleeps were standing in for.
        func awaitStreamRequest(_ count: Int) async { await requests.wait(until: count) }

        /// Ends Lane A **synchronously, on the caller's thread**, so the turn's
        /// resumption is enqueued on the brain's actor BEFORE anything the test
        /// does next. That ordering is the whole point: the test's following
        /// actor hop can then only be serviced once the turn has reached — and
        /// suspended inside — its join grace.
        func endHeldStream() {
            lock.lock()
            let continuation = heldStream
            heldStream = nil
            lock.unlock()
            continuation?.finish()
        }
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
        var delayNanoseconds: UInt64 = 0
        /// Park inside `dispatch` until `releaseDispatch()`. A lane that CANNOT
        /// finish beats a lane that probably won't: a duration long enough to
        /// outlast the join grace on an idle machine is not long enough on a
        /// loaded one, and a lane that finishes early JOINS — which silently
        /// deletes the routine the test is about to make assertions about.
        var holdsDispatch = false
        private let entered = ArrivalSignal()
        private let released = ArrivalSignal()

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

        /// Suspends until the `count`-th dispatch has BEGUN — "the lane is
        /// inside its tool", stated rather than assumed.
        func awaitDispatchEntered(_ count: Int) async { await entered.wait(until: count) }
        func releaseDispatch() { released.advance() }

        func dispatch(name: String, argumentsJSON: String, runID: String? = nil) async -> SkillOutcome {
            lock.lock()
            dispatched.append(name)
            let hold = holdsDispatch
            lock.unlock()
            entered.advance()
            if hold {
                await released.wait(until: 1)
            } else if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return SkillOutcome(ok: true, summary: "ok")
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

    /// Starts a turn, collects its events, and signals `firstToken` the moment
    /// Lane A's first token has been ACCUMULATED by the brain.
    ///
    /// THE FAILURE THIS PREVENTS: `awaitStreamRequest` is the wrong signal for
    /// any test that asserts on a PARTIAL reply. It advances inside `stream()`,
    /// synchronously, before the brain has read a single event off the stream
    /// it was just handed — so "Lane A was asked for" is true a long way before
    /// "Lane A has said anything". A token on the TURN's own stream is the fact
    /// those tests actually need: `runSeerLane` does `result.text += token` and
    /// only THEN yields `.token`, so observing one proves the accumulation has
    /// already happened.
    private func startTurn(
        _ brain: MaryBrain, _ text: String, firstToken: ArrivalSignal
    ) -> Task<[BrainEvent], Never> {
        let stream = brain.respond(to: text)
        return Task {
            var events: [BrainEvent] = []
            do {
                for try await event in stream {
                    events.append(event)
                    if case .token = event { firstToken.advance() }
                }
            } catch {}
            return events
        }
    }

    private func fullText(_ events: [BrainEvent]) -> String? {
        for event in events {
            if case .completed(let text) = event { return text }
        }
        return nil
    }

    // MARK: - Supersede removes the aborted exchange

    @Test func supersedeMidStreamReplacesExchange() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Partial thought")], hangAtEnd: true),
            .init(events: [.token("Amended reply.")]),
        ])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP"), .init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        let firstTurn = Task {
            try? await collect(brain.respond(to: "a timer for 3pm please"))
        }
        // Turn 1's Lane A is running and will never end (hangAtEnd) — so the
        // window for the amend is open from here on, rather than for 150 ms.
        await seer.awaitStreamRequest(1)

        let events = try await collect(
            brain.respondSuperseding("a timer for 3pm — actually 4 please"))
        _ = await firstTurn.value

        #expect(fullText(events) == "Amended reply.")
        // The amended request's Seer messages: just the amended user turn —
        // no original user turn, no partial assistant text.
        let amendedMessages = try #require(seer.callsSnapshot()[at: 1])
        #expect(amendedMessages.map(\.role) == ["user"])
        #expect(amendedMessages[at: 0]?.content == "a timer for 3pm — actually 4 please")
    }

    @Test func supersedeDropsAbortedToolPairs() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Working on it")], hangAtEnd: true),
            .init(events: [.token("Done differently.")]),
        ])
        let engine = ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),   // turn 1 lane: dispatches slowly
            .init(text: "NOOP"),             // amended turn lane
        ])
        let dispatcher = SlowDispatcher()
        dispatcher.delayNanoseconds = 800_000_000
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let firstTurn = Task {
            try? await collect(brain.respond(to: "run the probe"))
        }
        await dispatcher.awaitDispatchEntered(1)   // the lane IS inside dispatch

        _ = try await collect(brain.respondSuperseding("run the probe — never mind, just say hi"))
        // No unwind sleep: turn 1 was cancelled mid-Lane-A, and the barge-in
        // branch cancels the lane and then `await laneTask.value`s it — so the
        // superseded lane is provably finished by the time turn 1's stream ends.
        _ = await firstTurn.value

        // A follow-up turn's engine view must contain NO tool turns from the
        // aborted exchange: [user(amended), assistant(reply), user(next)].
        let seer2 = ScriptedSeer(scripts: [.init(events: [.token("ok")])])
        await brain.setSeerChat(seer2)
        _ = try await collect(brain.respond(to: "thanks"))
        let lastRequest = engine.requestsSnapshot().last
        #expect(lastRequest == [.user, .assistant, .user])
    }

    @Test func staleTurnCannotWriteAfterSupersede() async throws {
        // Turn 1 hangs mid-stream; supersede; turn 1's cancelled branch then
        // tries to append its partial — the stale epoch must drop it.
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Stale partial")], hangAtEnd: true),
            .init(events: [.token("Fresh reply.")]),
            .init(events: [.token("Next.")]),
        ])
        let engine = ScriptedEngine(rounds: (1...3).map { _ in .init(text: "NOOP") })
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        let firstTurn = Task { try? await collect(brain.respond(to: "original")) }
        await seer.awaitStreamRequest(1)
        _ = try await collect(brain.respondSuperseding("original — corrected"))
        // The stale append happens in the barge-in branch, strictly before
        // turn 1's stream finishes — so awaiting turn 1 IS the unwind window.
        _ = await firstTurn.value

        _ = try await collect(brain.respond(to: "next question"))
        let nextMessages = try #require(seer.callsSnapshot()[at: 2])
        #expect(nextMessages.map(\.role) == ["user", "assistant", "user"])
        #expect(nextMessages[at: 0]?.content == "original — corrected")
        #expect(nextMessages[at: 1]?.content == "Fresh reply.")
        #expect(!nextMessages.contains { $0.content.contains("Stale partial") })
    }

    /// The amended turn is a NEW identity: its .turnBegan id differs from
    /// the superseded turn's, so the transcript restamps the reused rows and
    /// later deferred writes can never resolve against the aborted turn.
    @Test func supersedingTurnMintsNewTurnID() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Partial thought")], hangAtEnd: true),
            .init(events: [.token("Amended reply.")]),
        ])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP"), .init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        let firstTurn = Task {
            try? await collect(brain.respond(to: "a timer for 3pm please"))
        }
        await seer.awaitStreamRequest(1)
        let amendedEvents = try await collect(
            brain.respondSuperseding("a timer for 3pm — actually 4 please"))
        let originalEvents = await firstTurn.value

        func leadingTurnID(_ events: [BrainEvent]?) -> UUID? {
            // An overlap-supersede notice may precede the identity;
            // .turnBegan still leads everything else.
            var events = (events ?? [])[...]
            if case .exchangeSuperseded? = events.first { events = events.dropFirst() }
            guard case .turnBegan(let id)? = events.first else { return nil }
            return id
        }
        let originalID = try #require(leadingTurnID(originalEvents))
        let amendedID = try #require(leadingTurnID(amendedEvents))
        #expect(originalID != amendedID, "a superseding turn mints a fresh identity")
    }

    @Test func supersedeWithNoPriorExchangeActsLikeRespond() async throws {
        let seer = ScriptedSeer(scripts: [.init(events: [.token("Hello!")])])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        let events = try await collect(brain.respondSuperseding("hi there"))
        #expect(fullText(events) == "Hello!")
        #expect(seer.callsSnapshot()[at: 0]?.map(\.role) == ["user"])
    }

    @Test func plainRespondDoesNotRemovePriorExchange() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("First.")]),
            .init(events: [.token("Second.")]),
        ])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP"), .init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        _ = try await collect(brain.respond(to: "one"))
        _ = try await collect(brain.respond(to: "two"))
        #expect(seer.callsSnapshot()[at: 1]?.map(\.role) == ["user", "assistant", "user"])
    }

    // MARK: - Overlap-supersede (plain respond over an in-flight turn)

    private func containsExchangeSuperseded(_ events: [BrainEvent]) -> Bool {
        events.contains { if case .exchangeSuperseded = $0 { return true }; return false }
    }

    /// Watches the proactive channel until the routine's terminal event —
    /// or a timeout, so a regression fails instead of hanging the suite.
    private func watchRoutineTerminal(
        _ stream: AsyncStream<ProactiveEvent>, timeoutSeconds: Double = 5
    ) async -> (spokeFollowUp: Bool, settled: Bool) {
        await withTaskGroup(of: (Bool, Bool).self) { group in
            group.addTask {
                var spoke = false
                for await event in stream {
                    if case .followUpToken = event { spoke = true }
                    if case .routineSettled = event { return (spoke, true) }
                    if case .routineCancelled = event { return (spoke, false) }
                }
                return (spoke, false)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return (false, false)
            }
            let first = await group.next() ?? (false, false)
            group.cancelAll()
            return (spokeFollowUp: first.0, settled: first.1)
        }
    }

    @Test func overlappingPlainRespondSupersedesInFlightTurn() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Partial thought")], hangAtEnd: true),
            .init(events: [.token("Fresh answer.")]),
        ])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP"), .init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        let firstTurn = Task {
            try? await collect(brain.respond(to: "first question"))
        }
        await seer.awaitStreamRequest(1)

        // A plain respond — NOT the amend flow — while turn 1 hangs.
        let events = try await collect(brain.respond(to: "second question"))
        let firstEvents = await firstTurn.value

        // The supersede notice leads the new stream, before identity and
        // any token, and names the REMOVED turn's user-turn id.
        guard case .exchangeSuperseded(let removedID)? = events.first else {
            Issue.record("overlap must lead with .exchangeSuperseded: \(events)")
            return
        }
        guard case .turnBegan(let firstID)? = firstEvents?.first else {
            Issue.record("turn 1 must lead with .turnBegan")
            return
        }
        #expect(removedID == firstID, "the notice carries the superseded turn's identity")
        guard case .turnBegan? = events.dropFirst().first else {
            Issue.record(".turnBegan must follow the supersede notice: \(events)")
            return
        }
        #expect(fullText(events) == "Fresh answer.")
        // Turn 2's Seer view: turn 1's user turn and partial are gone.
        let messages = try #require(seer.callsSnapshot()[at: 1])
        #expect(messages.map(\.role) == ["user"])
        #expect(messages[at: 0]?.content == "second question")
    }

    @Test func overlappingPlainRespondDropsAbortedToolPairs() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Working on it")], hangAtEnd: true),
            .init(events: [.token("Done differently.")]),
        ])
        let engine = ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),   // turn 1 lane: dispatches slowly
            .init(text: "NOOP"),             // overlapping turn's lane
        ])
        let dispatcher = SlowDispatcher()
        dispatcher.delayNanoseconds = 800_000_000
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let firstTurn = Task {
            try? await collect(brain.respond(to: "run the probe"))
        }
        await dispatcher.awaitDispatchEntered(1)   // the lane IS inside dispatch

        _ = try await collect(brain.respond(to: "forget that — just say hi"))
        // Same ordering as the amend sibling: the barge-in branch awaits the
        // cancelled lane, so turn 1's stream ending IS the unwind.
        _ = await firstTurn.value

        // A follow-up turn's engine view must contain NO tool turns from the
        // superseded exchange: [user(overlap), assistant(reply), user(next)].
        let seer2 = ScriptedSeer(scripts: [.init(events: [.token("ok")])])
        await brain.setSeerChat(seer2)
        _ = try await collect(brain.respond(to: "thanks"))
        let lastRequest = engine.requestsSnapshot().last
        #expect(lastRequest == [.user, .assistant, .user])
    }

    @Test func sequentialRespondsDoNotEmitExchangeSuperseded() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("First.")]),
            .init(events: [.token("Second.")]),
        ])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP"), .init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        _ = try await collect(brain.respond(to: "one"))
        let events = try await collect(brain.respond(to: "two"))
        #expect(!containsExchangeSuperseded(events),
                "a retired turn must never read as in-flight")
        #expect(seer.callsSnapshot()[at: 1]?.map(\.role) == ["user", "assistant", "user"])
    }

    @Test func cancelWithoutReplacementKeepsPartialExchange() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Partial answer")], hangAtEnd: true),
            .init(events: [.token("Next.")]),
        ])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP"), .init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        // THE FAILURE THIS PREVENTS (measured, 2 runs in 5): this waited on
        // `awaitStreamRequest(1)`, which fires before the brain has consumed a
        // single Seer event — so `cancel()` raced the partial into existence
        // and the assertions below came back ["user", "user"] with no partial
        // at all. The turn's own first token is the fact this test needs.
        let firstToken = ArrivalSignal()
        let firstTurn = startTurn(brain, "original", firstToken: firstToken)
        await firstToken.wait(until: 1)
        await brain.cancel()
        // The partial lands in the barge-in branch before the stream finishes.
        _ = await firstTurn.value

        // Barge-in with no replacement keeps the partial — the fresh turn
        // removes nothing and emits no supersede notice.
        let events = try await collect(brain.respond(to: "fresh question"))
        #expect(!containsExchangeSuperseded(events),
                "cancel() is barge-in keep-partial, never an overlap-supersede")
        let messages = try #require(seer.callsSnapshot()[at: 1])
        #expect(messages.map(\.role) == ["user", "assistant", "user"])
        #expect(messages[at: 1]?.content == "Partial answer")
    }

    /// LANDING INSIDE THE JOIN GRACE, BY CONSTRUCTION RATHER THAN BY CLOCK.
    ///
    /// THE FAILURE THIS PREVENTS (measured here, 10 runs out of 10, filtered or
    /// contended alike): this test used to drive a SPOKEN turn, end its Lane A
    /// by hand, and assume ONE actor hop was enough to carry `runTurn` from
    /// "Lane A returned" to "suspended inside `laneFinished`". It is not. The
    /// barge-in branch — `if Task.isCancelled` — sits between those two points,
    /// and draining Lane A's stream takes several actor turns to get past it.
    /// The overlap kept landing on the WRONG side of that check, so turn 1 left
    /// through barge-in, NO routine was ever born, and `settled` was false
    /// because there was nothing to settle. The scenario never happened; only
    /// the timeout did. A 100 ms sleep against a 250 ms wall clock had the same
    /// disease in the other direction — this is not a tighter guess, it is the
    /// removal of the guess.
    ///
    /// AN ACTION TURN DISSOLVES THE RACE INSTEAD OF NARROWING IT. It has no
    /// Lane A at all, so `runTurn` runs unbroken — no suspension point — from
    /// the lane spawn straight into `laneFinished`. The brain's actor is
    /// therefore not free until turn 1 is ALREADY parked in its grace, and
    /// `respond` is actor-isolated, so the overlap cannot possibly be serviced
    /// any earlier. Awaiting the dispatch first rules out the other direction,
    /// an overlap arriving before the lane even exists. The behaviour under
    /// test is identical either way: `supersededByNewTurn` is read from the
    /// same line of `runTurn` for both graces, only the constant differs.
    ///
    /// The 30 s grace is headroom, not a deadline to beat. It is what stops a
    /// loaded machine from turning "mid-grace" into "already detached" — the
    /// failure a fixed 250 ms window can always be starved into.
    @Test func overlapDuringGraceDetachesRoutineAsSuperseded() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("New topic reply.")]),   // the OVERLAP's Lane A
        ])
        let engine = ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),   // turn 1 lane: parked in dispatch
            .init(text: "NOOP"),             // overlapping turn's lane
        ])
        let dispatcher = SlowDispatcher()
        dispatcher.holdsDispatch = true   // the lane CANNOT join inside the grace
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)
        await brain.setActionJoinGraceForTesting(30_000_000_000)

        let proactiveStream = brain.proactiveEvents()
        let proactiveTask = Task { await watchRoutineTerminal(proactiveStream) }

        let firstTurn = Task {
            try? await collect(brain.respond(to: "add the probe hookup"))
        }
        await dispatcher.awaitDispatchEntered(1)
        let routinesBeforeOverlap = await brain.activeRoutineCount
        #expect(routinesBeforeOverlap == 0,
                "turn 1 must still be inside its join grace when the overlap lands")

        let events = try await collect(brain.respond(to: "tell me a joke instead"))
        #expect(containsExchangeSuperseded(events),
                "the overlap removed turn 1's open exchange")
        // The routine must exist BEFORE anything is asserted about how it
        // settles. Without this the whole test passes vacuously the day the
        // overlap starts landing pre-grace again — which is exactly how the
        // previous version failed, silently, with a five-second timeout.
        let routinesAfterOverlap = await brain.activeRoutineCount
        #expect(routinesAfterOverlap == 1,
                "the mid-grace lane must detach as a routine, not leave via barge-in")
        // The superseded routine's probe may return now.
        dispatcher.releaseDispatch()
        _ = await firstTurn.value

        // The mid-grace lane detached as a routine BORN superseded: all-ok
        // outcomes settle silently, and its doneMarker merge drops because
        // the origin exchange is gone.
        let outcome = await proactiveTask.value
        #expect(outcome.settled, "the superseded routine must still settle terminally")
        #expect(!outcome.spokeFollowUp, "an all-ok superseded routine settles silently")

        let spoken = await brain.spokenMessagesForTesting()
        #expect(!spoken.contains { $0.content.contains("(done:") },
                "the merge must drop — its origin exchange was removed")
        #expect(spoken.map(\.role) == ["user", "assistant"],
                "history holds exactly the superseding exchange: \(spoken.map(\.content))")
    }

    @Test func overlapPreservesUnrelatedDetachedRoutines() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("On it.")]),                       // turn 1 → routine
            .init(events: [.token("Hanging.")], hangAtEnd: true),    // turn 2 hangs
            .init(events: [.token("Third.")]),                       // turn 3 overlaps
        ])
        let engine = ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),   // turn 1 lane: slow dispatch
            .init(text: "NOOP"),             // turn 2 lane
            .init(text: "NOOP"),             // turn 3 lane
        ])
        let dispatcher = SlowDispatcher()
        // Parked rather than merely slow: "the routine is STILL running while
        // turns 2→3 supersede each other" is the premise of this test, and a
        // duration only makes it probable.
        dispatcher.holdsDispatch = true
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let proactiveStream = brain.proactiveEvents()
        let proactiveTask = Task { await watchRoutineTerminal(proactiveStream) }

        // Turn 1 completes, its slow lane detaches into a routine.
        _ = try await collect(brain.respond(to: "run the slow probe"))
        let active = await brain.isRoutineActive
        #expect(active)

        // Turns 2→3 overlap-supersede each other — the routine is untouched.
        let secondTurn = Task { try? await collect(brain.respond(to: "hanging question")) }
        await seer.awaitStreamRequest(2)   // turn 2 is in its hanging Lane A
        let events = try await collect(brain.respond(to: "actually this instead"))
        _ = await secondTurn.value
        #expect(containsExchangeSuperseded(events))

        // Only now may the untouched routine finish.
        dispatcher.releaseDispatch()
        let settled = await proactiveTask.value.settled
        #expect(settled, "the unrelated routine still completes and settles")
        #expect(dispatcher.dispatchedSnapshot().contains("probe"), "its dispatch genuinely ran")
        let stillActive = await brain.isRoutineActive
        #expect(!stillActive)

        // Its doneMarker merged into the ORIGIN exchange — untouched by the
        // turn 2→3 supersede.
        let spoken = await brain.spokenMessagesForTesting()
        #expect(spoken.contains { $0.role == "assistant" && $0.content.hasPrefix("On it.\n\n(done: probe") },
                "\(spoken.map(\.content))")
    }

    /// D3's core contract, pinned: a superseded turn's stream ends WITHOUT
    /// .completed — a superseded TEXT turn's runner must never receive a
    /// terminal payload it would finalize the NEW turn's bubble with.
    @Test func supersededStreamEndsWithoutCompleted() async throws {
        let seer = ScriptedSeer(scripts: [
            .init(events: [.token("Hanging thought")], hangAtEnd: true),
            .init(events: [.token("Second reply.")]),
        ])
        let engine = ScriptedEngine(rounds: [.init(text: "NOOP"), .init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: SlowDispatcher())
        await brain.setSeerChat(seer)

        let firstTurn = Task { try? await collect(brain.respond(to: "one")) }
        await seer.awaitStreamRequest(1)
        _ = try await collect(brain.respond(to: "two"))
        let firstEvents = await firstTurn.value ?? []

        #expect(fullText(firstEvents) == nil)
    }

    /// A silent action turn cancelled mid-grace with NO replacement (a
    /// follow-up preempt) must still close its exchange: spokenMessages()
    /// drops empty assistants, so a stranded user turn would put two
    /// consecutive user roles on every later request. The factual marker
    /// keeps alternation and anchors the routine's follow-up merge.
    @Test func cancelledActionTurnClosesExchangeWithMarker() async throws {
        let seer = ScriptedSeer(scripts: [])   // an action turn never calls Seer
        let engine = ScriptedEngine(rounds: [.init(calls: [call("probe")])])
        let dispatcher = SlowDispatcher()
        dispatcher.delayNanoseconds = 1_000_000_000
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let proactiveStream = brain.proactiveEvents()
        let settleWatcher = Task { await watchRoutineTerminal(proactiveStream) }

        let turn = Task { try? await collect(brain.respond(to: "add the probe hookup")) }
        // An ACTION turn has no Lane A, so `runTurn` runs unbroken from the
        // lane spawn to `laneFinished` — which makes `cancel()`, an
        // actor-isolated call, land inside the action join grace by
        // construction: the actor is not free until the turn is suspended in
        // it. Waiting for the dispatch first is what rules out the OTHER
        // direction, a cancel that arrives before the lane even exists.
        await dispatcher.awaitDispatchEntered(1)
        await brain.cancel()
        _ = await turn.value
        // The detached routine finishes, merges its doneMarker and settles —
        // waited for on the channel that announces it rather than by clock.
        let settled = await settleWatcher.value.settled
        #expect(settled, "the cancelled action turn's routine must still settle")

        let messages = await brain.spokenMessagesForTesting()
        for (a, b) in zip(messages, messages.dropFirst()) {
            #expect(a.role != b.role, "consecutive \(a.role) breaks alternation")
        }
        #expect(messages.last?.role == "assistant")
        #expect(messages.last?.content.hasPrefix("(on it)") == true,
                "\(messages.map(\.content))")
    }
}

// MARK: - Subprocess kill-on-cancel

@Suite struct SubprocessCancelTests {

    @Test func cancellationTerminatesChildQuickly() async throws {
        let started = Date()
        let task = Task {
            try await Subprocess.run("/bin/sleep", ["20"], timeout: 60)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = try? await task.value
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3, "SIGTERM on cancel must end the child well before the 20s sleep")
    }

    @Test func alreadyCancelledTaskNeverSpawns() async throws {
        let task = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return try await Subprocess.run("/bin/sleep", ["20"], timeout: 60)
        }
        task.cancel()
        let result = try? await task.value
        #expect(result == nil)
    }

    @Test func normalRunUnaffected() async throws {
        let result = try await Subprocess.run("/bin/echo", ["hello"], timeout: 10)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("hello"))
    }
}

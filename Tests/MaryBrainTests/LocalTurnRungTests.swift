//
//  LocalTurnRungTests.swift
//  MaryBrainTests
//
//  WHAT: The two rungs the local turn gained — the continuation nudge and the
//        deterministic press — fire on exactly the turns the orchestrator's do.
//  OUT:  MaryBrain+LocalTurn
//  PIN:  LOCAL IS NOT A LESSER TURN, and this is the suite that keeps it honest. These
//        rungs run for every person who has no Sewn, so the CONDITIONS matter more than
//        the behaviour: a turn whose work landed must not be talked over, a turn that is
//        not an action must not be pressed on, and the words a lane says to itself must
//        not survive as words the person said.
//        THE LANE IS CALLED DIRECTLY, WITH A ROUTE. `route` is localTurn's input, not its
//        business — which turns route as `.operate` is `TurnTriage`'s question and has its
//        own suite. Driving `respond(to:)` here would test the router instead, and with no
//        semantic index in a unit test the triage abstains and no turn is ever an action.
//

import Foundation
import Testing
import MaryAmbient
import MaryVoice
@testable import MaryPlugin
@testable import MaryBrain

@Suite(.serialized) struct LocalTurnRungTests {

    // MARK: - The continuation nudge

    /// ONLY READ, ON A TURN THAT ASKED FOR SOMETHING DONE → one more round, once.
    @Test func aReadOnlyOutcomeOnAnActingTurnEarnsOneContinuation() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["probe"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: "{}")]),
            .init(text: "I had a look."),   // the round that gets nudged
            .init(text: "Still just looking."),
            .init(text: "And again."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await Self.runLocalTurn(brain, "fix the total", route: Self.route(action: true))

        #expect(Self.nudgeCount(engine, MaryPrompts.continuationNudge) == 1)
    }

    /// A TURN WHOSE WORK LANDED IS NOT NUDGED. The receipt is the whole point: `landed`
    /// is the browsing lane's proof that the asked-for change happened, and a lane that
    /// nudges anyway spends a round asking for work that is already done.
    @Test func anOutcomeThatLandedIsNotContinued() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["probe"]
        dispatcher.landedTools = ["probe"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: "{}")]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await Self.runLocalTurn(brain, "fix the total", route: Self.route(action: true))

        #expect(Self.nudgeCount(engine, MaryPrompts.continuationNudge) == 0)
    }

    /// AN OUTCOME THAT COMMITTED IS NOT NUDGED EITHER — the rung asks only about turns
    /// where every outcome merely read or staged a surface.
    @Test func aCommittingOutcomeIsNotContinued() async throws {
        // Not read-only, not non-effectful, not surface-preparing: it did the thing.
        let dispatcher = BrainFakes.StubDispatcher()
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: "{}")]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await Self.runLocalTurn(brain, "fix the total", route: Self.route(action: true))

        #expect(Self.nudgeCount(engine, MaryPrompts.continuationNudge) == 0)
    }

    /// AND A CONVERSATIONAL TURN IS NEVER CONTINUED. It has already streamed its prose
    /// live, so a second round would say the same thing twice — the PIN's own reason for
    /// gating on `actionTurn` rather than the orchestrator's wider reading.
    @Test func aNonActionTurnIsNeverContinued() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["probe"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: "{}")]),
            .init(text: "Here's what I saw."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await Self.runLocalTurn(
            brain, "what does the total say", route: Self.route(action: false))

        #expect(Self.nudgeCount(engine, MaryPrompts.continuationNudge) == 0)
    }

    // MARK: - The screen's own offer

    /// NAMED ONCE, THEN PRESSED. The model was told what the screen offers, declined it
    /// twice, and the control clears the confident floor — so the rung presses it rather
    /// than reporting a failure the person can see is wrong.
    @Test func theScreensOfferIsNamedOnceThenPressed() async throws {
        Self.publishOffer()
        defer { Self.retractOffer() }
        let dispatcher = BrainFakes.StubDispatcher()
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(text: "I'm not sure which one you mean."),
            .init(text: "Still not sure."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await Self.runLocalTurn(
            brain, "press accept all", route: Self.route(action: true))

        let nudges = Self.historyCount(engine) { MaryPrompts.isAffordanceNudge($0) }
        #expect(nudges == 1, "the screen's offer was named \(nudges) times, not once")
        #expect(dispatcher.dispatchedSnapshot() == ["act_on_screen"])
    }

    /// NOTHING ON OFFER, NOTHING PRESSED — the honest line instead.
    ///
    /// PIN: This is also the state a bench runs in until a page read publishes a slate,
    /// which is why the rung is inert there rather than dangerous.
    @Test func withNoOfferTheTurnSaysItCouldNotAct() async throws {
        Self.retractOffer()
        let dispatcher = BrainFakes.StubDispatcher()
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(text: "I'm not sure."),
            .init(text: "Still not sure."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let events = try await Self.runLocalTurn(
            brain, "press accept all", route: Self.route(action: true))

        #expect(dispatcher.dispatchedSnapshot().isEmpty)
        #expect(Self.spoken(events).contains("I couldn't work out how to do that"))
    }

    /// NAMED, BUT NOT PRESSED. The screen offers something that plausibly serves and the
    /// probe is only 0.6 sure of it — so the lane says which control it means and stops.
    /// The floor is the whole difference between a deterministic rung and a guess made
    /// with someone else's mouse.
    @Test func anOfferBelowTheConfidentFloorIsNamedButNotPressed() async throws {
        Self.installVectorizer()
        Self.publishNearOffer()
        defer { Self.retractOffer(); Self.removeVectorizer() }
        // The fixture is only meaningful if it sits BETWEEN the two thresholds.
        let measured = AffordanceProbe.candidate(for: Self.nearGoal)?.score ?? 0
        #expect(measured >= AmbientReferenceGate.acceptanceThreshold)
        #expect(measured < AffordanceProbe.confidentFloor)

        let dispatcher = BrainFakes.StubDispatcher()
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(text: "I'm not sure."),
            .init(text: "Still not sure."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let events = try await Self.runLocalTurn(
            brain, Self.nearGoal, route: Self.route(action: true))

        #expect(Self.historyCount(engine) { MaryPrompts.isAffordanceNudge($0) } == 1)
        #expect(dispatcher.dispatchedSnapshot().isEmpty)
        #expect(Self.spoken(events).contains("I couldn't work out how to do that"))
    }

    /// AND THE PRESS STAYS OFF A CONVERSATIONAL TURN. A question about the screen is not
    /// permission to touch it.
    @Test func theOfferIsNotPressedOnANonActionTurn() async throws {
        Self.publishOffer()
        defer { Self.retractOffer() }
        let dispatcher = BrainFakes.StubDispatcher()
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(text: "There's an Accept all button."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await Self.runLocalTurn(
            brain, "what does accept all do", route: Self.route(action: false))

        #expect(dispatcher.dispatchedSnapshot().isEmpty)
    }

    // MARK: - History

    /// THE LANE'S OWN WORDS DO NOT SURVIVE THE TURN. A synthetic `.user` turn left in
    /// shared history is a sentence the person never said, quoted back at them next time.
    @Test func syntheticNudgesArePrunedFromHistory() async throws {
        Self.publishOffer()
        defer { Self.retractOffer() }
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["probe"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: "{}")]),
            .init(text: "I had a look."),
            .init(text: "Still looking."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await Self.runLocalTurn(
            brain, "press accept all", route: Self.route(action: true))

        // The nudge WAS said — otherwise this proves nothing about the prune.
        #expect(Self.nudgeCount(engine, MaryPrompts.continuationNudge) == 1)
        let remembered = await brain.history.map(\.text)
        #expect(!remembered.contains(MaryPrompts.continuationNudge))
        #expect(!remembered.contains { MaryPrompts.isAffordanceNudge($0) })
        #expect(!remembered.contains(MaryBrain.groundedRetryNudge))
    }

    /// The recognizer the prune depends on actually recognizes the nudge it is given —
    /// and nothing else. A prune that matched loosely would eat the person's own words.
    @Test func theAffordanceNudgeIsRecognizable() {
        let nudge = MaryPrompts.affordanceNudge(labels: ["Accept all", "Reject"])
        #expect(MaryPrompts.isAffordanceNudge(nudge))
        #expect(!MaryPrompts.isAffordanceNudge("press accept all"))
        #expect(!MaryPrompts.isAffordanceNudge(MaryPrompts.continuationNudge))
    }

    // MARK: - A question never ends in silence

    /// THE READ RAN AND THE MODEL SAID NOTHING — the shape of the reported bug.
    ///
    /// "What is this page about?" reads the page (1–3s), and a small local model
    /// then returns an empty round. This exit used to complete with an empty
    /// `fullText`: the person watched "still working" flip back to "Listening"
    /// having been told nothing, with the answer sitting in the skill result.
    /// The passage is in hand, so it is spoken.
    @Test func aReadThatTheModelDoesNotNarrateIsStillSpoken() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["read_page_text"]
        dispatcher.results = ["read_page_text": Self.passage]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "read_page_text", argumentsJSON: "{}")]),
            .init(text: ""),   // the empty retry
            .init(text: ""),   // and the round after it
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let events = try await Self.runLocalTurn(
            brain, "what is this page about?", route: Self.route(action: false))

        let spoken = Self.spokenText(events)
        #expect(
            spoken.contains("Ski touring is skiing in the backcountry"),
            "the turn said: \(spoken.isEmpty ? "(nothing)" : spoken)")
        // AND THE HEADER IS NOT THE ANSWER — a listing's first line is a label.
        #expect(!spoken.hasPrefix("The visible part"))
    }

    /// AND A TURN THAT DID SPEAK IS NOT TALKED OVER. The rung is a last resort,
    /// not a second voice: whatever the model said stands on its own.
    @Test func aReadTheModelDoesNarrateIsNotRepeated() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["read_page_text"]
        dispatcher.results = ["read_page_text": Self.passage]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "read_page_text", argumentsJSON: "{}")]),
            .init(text: "It's about ski touring."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let events = try await Self.runLocalTurn(
            brain, "what is this page about?", route: Self.route(action: false))

        let spoken = Self.spokenText(events)
        #expect(spoken.contains("It's about ski touring."))
        #expect(!spoken.contains("backcountry"), "the passage was read out over the answer")
    }

    /// THE PASSAGE ITSELF, as the deterministic voice takes it: header dropped,
    /// clamped to two breaths, and empty when there is nothing readable to say.
    @Test func theReadBackTakesThePassageAndNotItsHeader() {
        let read = MaryBrain.LaneOutcome(
            skillName: "read_page_text",
            outcome: SkillOutcome(ok: true, summary: Self.passage))
        let line = MaryBrain.spokenReadBack(outcomes: [read])
        #expect(line.hasPrefix("Ski touring"))
        #expect(!line.contains("The visible part"))
        #expect(line.count <= MaryBrain.readBackClamp + 1)

        // A MISS IS NOT A PASSAGE, and neither is a failure.
        let miss = MaryBrain.LaneOutcome(
            skillName: "read_page_text",
            outcome: SkillOutcome(
                ok: true, summary: "I can read nothing on this page.",
                foundNothing: true))
        #expect(MaryBrain.spokenReadBack(outcomes: [miss]).isEmpty)
    }

    private static let passage = """
        The visible part of Ski touring, top to bottom:
        Ski touring
        Ski touring is skiing in the backcountry on unmarked slopes.
        """

    /// Everything the turn actually said, in order.
    private static func spokenText(_ events: [BrainEvent]) -> String {
        events.reduce(into: "") { text, event in
            if case .token(let token) = event { text += token }
        }
    }

    // MARK: - Harness

    /// The route as the turn loop would have handed it down. `.operate` is what
    /// `isActionTurn` reads; the verdict is set to match so nothing downstream disagrees.
    private static func route(action: Bool) -> AmbientRoute {
        AmbientRoute(
            intent: action ? .operate : .converse,
            decidedBy: .embedding,
            verdicts: AmbientVerdicts(actionTurn: action))
    }

    /// A fresh brain's epoch is 0, so `appendHistory` accepts every append this makes.
    private static func runLocalTurn(
        _ brain: MaryBrain, _ text: String, route: AmbientRoute
    ) async throws -> [BrainEvent] {
        let stream = AsyncThrowingStream<BrainEvent, Error> { continuation in
            Task {
                await brain.localTurn(
                    userText: text, systemPrompt: "", route: route,
                    continuation: continuation, epoch: 0)
                continuation.finish()
            }
        }
        var events: [BrainEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// A consent wall, as a page read would have published one.
    private static func publishOffer() {
        AmbientElementIndexStore.shared.noteElements(
            AffordanceRule.records(
                for: [
                    AmbientAffordance(
                        id: "accept", label: "Accept all", roleWord: "button", ordinal: 1),
                    AmbientAffordance(
                        id: "reject", label: "Reject", roleWord: "button", ordinal: 2),
                ],
                scope: offerScope),
            scope: offerScope)
    }

    /// SHARED STATE, PUT BACK. `.shared` is process-wide and the probe scans every fresh
    /// slate, so a leaked offer would be on screen for suites that never published one.
    private static func retractOffer() {
        AmbientElementIndexStore.shared.noteElements([], scope: offerScope)
    }

    private static let offerScope = AmbientElementScope.affordances(
        in: .application("com.test.local-turn-rungs"))

    /// A control that answers the goal only by meaning — no shared word, so nothing
    /// lexical can floor it up to certainty.
    private static let nearGoal = "consent to the notice"

    private static func publishNearOffer() {
        AmbientElementIndexStore.shared.noteElements(
            AffordanceRule.records(
                for: [AmbientAffordance(
                    id: "agree", label: "Agree", roleWord: "button", ordinal: 1)],
                scope: offerScope),
            scope: offerScope)
    }

    /// 0.6 between the goal and the control, and nothing else vectorizes at all.
    ///
    /// PIN: `.shared` IS PROCESS-WIDE, so this installs for one test and takes it back
    /// out. Only this suite publishes into the shared store, and `rank` reads vectors
    /// only for a scope that has an index — so a stray cached vector reaches nothing.
    private static func installVectorizer() {
        AmbientElementIndexStore.shared.installVectorizer(
            ProbeVectorizer(vectors: [nearGoal: [1, 0], "agree": [0.6, 0.8]]))
    }

    private static func removeVectorizer() {
        AmbientElementIndexStore.shared.installVectorizer(nil)
    }

    private struct ProbeVectorizer: AmbientTextVectorizer {
        let vectors: [String: [Float]]
        func vector(for text: String) -> [Float]? {
            vectors[text.lowercased()]
        }
    }

    /// How many rounds were shown a history containing this exact synthetic turn — the
    /// nudge's only observable effect, since the prune removes it before the turn ends.
    private static func nudgeCount(
        _ engine: BrainFakes.ScriptedEngine, _ text: String
    ) -> Int {
        historyCount(engine) { $0 == text }
    }

    private static func historyCount(
        _ engine: BrainFakes.ScriptedEngine, _ matches: (String) -> Bool
    ) -> Int {
        engine.historyTextsSnapshot().filter { $0.contains(where: matches) }.count
    }

    private static func spoken(_ events: [BrainEvent]) -> String {
        events.reduce(into: "") { text, event in
            if case .token(let token) = event { text += token }
        }
    }
}

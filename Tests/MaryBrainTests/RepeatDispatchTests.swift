//
//  RepeatDispatchTests.swift
//  MaryBrainTests
//
//  WHAT: The lane stops re-running what it just ran — a question ends it, a
//        failed call is not repeated, an unproven act waits for a look.
//  OUT:  MaryBrain+RepeatGuard; the lanes' question exit; groundedResultsBlock
//  PIN:  MEASURED: "skip the ad" dispatched three times — once landing on a
//        weak receipt, then twice refused as ambiguous — because the round loop
//        asks the model again after every dispatch and nothing compared a call
//        with the one before it. These are the three places it now declines,
//        on BOTH lanes, and the labels the model reads instead of "FAILED".
//        THE LANE IS CALLED DIRECTLY, WITH A ROUTE — the same reason as
//        EngineTurnRungTests: with no semantic index no turn is ever an action.
//

import Foundation
import Testing
import MaryAmbient
import MaryVoice
@testable import MaryPlugin
@testable import MaryBrain

@Suite(.serialized) struct RepeatDispatchTests {

    static let skipTheAd = #"{"goal":"skip the ad"}"#
    static let whichOne = "There's more than one \"skip the ad\" on this page — \"My Ad Center\", \"Why you're seeing this ad\". Which one?"

    // MARK: - Engine seat (no Lane A)

    /// A QUESTION ENDS THE LANE, AND IS THE REPLY — not "that didn't go through".
    @Test func aQuestionEndsTheEngineTurn() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.failingTools = ["probe"]
        dispatcher.askingTools = ["probe"]
        dispatcher.results["probe"] = Self.whichOne
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let events = try await Self.runEngineTurn(brain, "skip the ad", route: Self.route(action: true))

        #expect(dispatcher.dispatchedSnapshot() == ["probe"])
        #expect(engine.requestsSnapshot().count == 1, "the lane ended on the question")
        let spoken = Self.spoken(events)
        #expect(spoken.contains("Which one?"))
        #expect(!spoken.contains("didn't go through"))
    }

    /// THE SAME CALL THAT JUST FAILED IS NOT TRIED AGAIN.
    @Test func aFailedCallIsNotRepeatedWithTheSameWords() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.failingTools = ["probe"]
        dispatcher.results["probe"] = "I couldn't find \"the purple button\" on the page."
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: #"{"goal":"the purple button"}"#)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: #"{"goal":"the purple button"}"#)]),
            .init(text: "Still trying."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let events = try await Self.runEngineTurn(brain, "click the purple button", route: Self.route(action: true))

        #expect(dispatcher.dispatchedSnapshot() == ["probe"])
        #expect(engine.requestsSnapshot().count == 2, "the repeat was refused and the turn wrapped up")
        #expect(Self.spoken(events).contains("didn't go through"))
    }

    /// DIFFERENT WORDS ARE A DIFFERENT CALL.
    @Test func differentWordsAreNotARepeat() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.failingTools = ["probe"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: #"{"goal":"x"}"#)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: #"{"goal":"y"}"#)]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        _ = try await Self.runEngineTurn(brain, "click it", route: Self.route(action: true))
        #expect(dispatcher.dispatchedSnapshot() == ["probe", "probe"])
    }

    /// KEY ORDER IS NOT A DIFFERENCE — the same object is the same call.
    @Test func keyOrderIsNotADifference() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.failingTools = ["probe"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: #"{"a":1,"b":2}"#)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: #"{"b":2, "a":1}"#)]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        _ = try await Self.runEngineTurn(brain, "click it", route: Self.route(action: true))
        #expect(dispatcher.dispatchedSnapshot().count == 1)
    }

    /// AN ACT THAT RAN UNPROVEN IS HELD, AND THE MODEL IS TOLD TO LOOK.
    @Test func anUnprovenActIsNotRepeatedWithoutALook() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.results["probe"] = "click \"skip the ad\" — the page changed (72 new, 77 gone)."
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await Self.runEngineTurn(brain, "skip the ad", route: Self.route(action: true))

        #expect(dispatcher.dispatchedSnapshot() == ["probe"])
        #expect(engine.requestsSnapshot().count == 3, "the lane continued — the model may look, or stop")
        let heard = engine.historyTextsSnapshot().last ?? []
        #expect(heard.contains { $0.contains("unproven — look before running it again") })
    }

    /// A PROVEN ACT MAY BE REPEATED — "next track" twice is two skips.
    @Test func aProvenActMayRepeat() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.landedTools = ["probe"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: #"{"action":"next"}"#)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: #"{"action":"next"}"#)]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        _ = try await Self.runEngineTurn(brain, "skip two songs", route: Self.route(action: true))
        #expect(dispatcher.dispatchedSnapshot() == ["probe", "probe"])
    }

    /// AFTER A LOOK THE SAME ACT IS ADMISSIBLE AGAIN — the rule keys on the most
    /// recent outcome, and a read is how one checks.
    @Test func anUnprovenRepeatAfterALookIsAllowed() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["look"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(calls: [.init(id: "2", name: "look", argumentsJSON: "{}")]),
            .init(calls: [.init(id: "3", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        _ = try await Self.runEngineTurn(brain, "skip the ad", route: Self.route(action: true))
        #expect(dispatcher.dispatchedSnapshot() == ["probe", "look", "probe"])
    }

    // MARK: - Orchestrator lane

    @Test func aQuestionEndsTheOrchestratorLane() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.failingTools = ["probe"]
        dispatcher.askingTools = ["probe"]
        dispatcher.results["probe"] = Self.whichOne
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let result = await Self.runLane(brain, "skip the ad")

        #expect(dispatcher.dispatchedSnapshot() == ["probe"])
        #expect(result.question == Self.whichOne)
        #expect(engine.requestsSnapshot().count == 1)
    }

    @Test func aFailedCallIsNotRepeatedInTheOrchestratorLane() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.failingTools = ["probe"]
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(text: "Still trying."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let result = await Self.runLane(brain, "skip the ad")

        #expect(dispatcher.dispatchedSnapshot() == ["probe"])
        #expect(result.repeatedFailedCall)
        #expect(engine.requestsSnapshot().count == 2)
    }

    @Test func anUnprovenActIsHeldInTheOrchestratorLane() async throws {
        let dispatcher = BrainFakes.StubDispatcher()
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [.init(id: "1", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(calls: [.init(id: "2", name: "probe", argumentsJSON: Self.skipTheAd)]),
            .init(text: "Done."),
        ])
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let result = await Self.runLane(brain, "skip the ad")

        #expect(dispatcher.dispatchedSnapshot() == ["probe"])
        #expect(!result.repeatedFailedCall)
        #expect(engine.requestsSnapshot().count == 3)
    }

    // MARK: - What the model reads

    /// FOUR LABELS: DONE is proven, RAN, unproven is delivered without a receipt,
    /// ASKED is the person's to answer, FAILED did not go through. A read is plain.
    @Test func groundedResultsLabelDoneRanAskedFailed() {
        let outcomes = [
            MaryBrain.LaneOutcome(skillName: "a", outcome: SkillOutcome(ok: true, summary: "went", landed: true)),
            MaryBrain.LaneOutcome(skillName: "b", outcome: SkillOutcome(ok: true, summary: "page changed")),
            MaryBrain.LaneOutcome(skillName: "c", outcome: SkillOutcome(ok: false, summary: "Which one?", asksThePerson: true)),
            MaryBrain.LaneOutcome(skillName: "d", outcome: SkillOutcome(ok: false, summary: "broke")),
            MaryBrain.LaneOutcome(skillName: "e", outcome: SkillOutcome(ok: true, summary: "the text")),
        ]
        let block = MaryBrain.groundedResultsBlock(outcomes: outcomes, isRead: { $0 == "e" })
        #expect(block.contains("- a DONE: went"))
        #expect(block.contains("- b RAN, unproven: page changed"))
        #expect(block.contains("- c ASKED: Which one?"))
        #expect(block.contains("- d FAILED: broke"))
        #expect(block.contains("- e: the text"))
    }

    /// A QUESTION IS NOT AN UNRECOVERED FAILURE; it is the open question.
    @Test func aQuestionIsNotAFailureToReport() {
        let asked = MaryBrain.LaneOutcome(
            skillName: "c", outcome: SkillOutcome(ok: false, summary: "Which one?", asksThePerson: true))
        #expect(MaryBrain.unrecoveredFailure(in: [asked]) == nil)
        #expect(MaryBrain.openQuestion(in: [asked])?.summary == "Which one?")
        #expect(MaryBrain.fallbackFollowUpLine(outcomes: [asked]) == "Which one?")
    }

    // MARK: - Helpers

    private static func route(action: Bool) -> AmbientRoute {
        AmbientRoute(
            intent: action ? .operate : .converse,
            decidedBy: .embedding,
            verdicts: AmbientVerdicts(actionTurn: action))
    }

    private static func runEngineTurn(
        _ brain: MaryBrain, _ text: String, route: AmbientRoute
    ) async throws -> [BrainEvent] {
        let stream = AsyncThrowingStream<BrainEvent, Error> { continuation in
            Task {
                await brain.engineTurn(
                    userText: text, systemPrompt: "", route: route,
                    continuation: continuation, epoch: 0)
                continuation.finish()
            }
        }
        var events: [BrainEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private static func runLane(_ brain: MaryBrain, _ text: String) async -> MaryBrain.OrchestratorLaneResult {
        var held: AsyncThrowingStream<BrainEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<BrainEvent, Error> { held = $0 }
        let emitter = LaneEmitter(continuation: held!)
        let result = await brain.runOrchestratorLane(
            userText: text, systemPrompt: "", seed: [], emitter: emitter,
            actionTurn: true, routeIntent: .operate)
        held?.finish()
        _ = stream
        return result
    }

    private static func spoken(_ events: [BrainEvent]) -> String {
        events.compactMap { event -> String? in
            if case .token(let text) = event { return text }
            return nil
        }.joined()
    }
}

/// THE RUNTIME CARRIES THE RULE IT ALREADY APPLIED: a failure whose summary is
/// a question gets no hint — and now says it asks.
@Suite struct AsksThePersonRuntimeTests {

    private static func binding(_ summary: String) -> SkillBinding {
        SkillBinding(
            name: "poke",
            description: "test",
            parameters: [],
            access: .read,
            backing: .native { _, _ in SkillOutcome(ok: false, summary: summary) },
            spokenFailureHint: "check Accessibility in my Settings")
    }

    @Test func aFailedQuestionAsksThePersonAndGetsNoHint() async {
        let registry = AbilityRuntime(plugins: [], standalone: [Self.binding("Which one?")]) {
            AbilityExecutionContext(projects: [:])
        }
        registry.beginTurn()
        let outcome = await registry.dispatch(name: "poke", argumentsJSON: "{}")
        #expect(outcome.asksThePerson)
        #expect(outcome.summary == "Which one?")
    }

    @Test func aPlainFailureIsHintedAndDoesNotAsk() async {
        let registry = AbilityRuntime(plugins: [], standalone: [Self.binding("It broke.")]) {
            AbilityExecutionContext(projects: [:])
        }
        registry.beginTurn()
        let outcome = await registry.dispatch(name: "poke", argumentsJSON: "{}")
        #expect(!outcome.asksThePerson)
        #expect(outcome.summary.contains("check Accessibility"))
    }
}

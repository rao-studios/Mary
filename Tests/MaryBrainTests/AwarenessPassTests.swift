//
//  AwarenessPassTests.swift
//  MaryBrainTests
//
//  WHAT: The pre-lane awareness pass — when it runs, what it hands the voice,
//        and how the voice is told to speak it.
//  OUT:  AbilityRuntime.fetchAwareness / SeerPass / MaryPrompts.seerInstructions
//  PIN:  Every new input defaults empty, so a pass that traced nothing renders
//        the byte-identical prompt every other suite already pins.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct AwarenessPassTests {

    // MARK: - The prompt is untouched when nothing was traced

    @Test func anEmptyPassRendersTheSamePromptAsBefore() {
        #expect(MaryPrompts.seerInstructions(awareness: [])
                == MaryPrompts.seerInstructions())
        #expect(MaryPrompts.seerInstructions(
            liveWork: ["THE_LIVE_BLOCK"],
            liveWorkWorld: .document(name: "Xcode", whole: false),
            readPassages: ["THE_READ"],
            awareness: [])
                == MaryPrompts.seerInstructions(
                    liveWork: ["THE_LIVE_BLOCK"],
                    liveWorkWorld: .document(name: "Xcode", whole: false),
                    readPassages: ["THE_READ"]))
    }

    // MARK: - Where the bearings land, and how they are framed

    /// ORDER IS THE DOCTRINE: on-screen work, then what is held, then what was
    /// traced, and the READ stays the last word.
    @Test func bearingsLandAfterHeldFactsAndBeforeTheRead() throws {
        let text = MaryPrompts.seerInstructions(
            liveWork: ["THE_LIVE_BLOCK"],
            liveWorkWorld: .document(name: "Xcode", whole: false),
            heldFacts: ["THE_HELD_BLOCK"],
            readPassages: ["THE_READ_BLOCK"],
            perceiving: true,
            awareness: ["THE_TRACED_BLOCK"])
        let held = try #require(text.range(of: "THE_HELD_BLOCK")).lowerBound
        let traced = try #require(text.range(of: "THE_TRACED_BLOCK")).lowerBound
        let read = try #require(text.range(of: "THE_READ_BLOCK")).lowerBound
        #expect(held < traced)
        #expect(traced < read)
    }

    /// The frame says what the bearings ARE and how to speak them — a file
    /// and a line are for finding things again, never for reading aloud.
    @Test func theFrameForbidsSpeakingTheBearingsAloud() {
        let text = MaryPrompts.seerInstructions(
            liveWork: ["THE_LIVE_BLOCK"],
            liveWorkWorld: .document(name: "Xcode", whole: false),
            awareness: ["- open — Sources/Session.swift:6: return reader.read()"])
        #expect(text.contains("I also traced this just now"))
        #expect(text.contains("These are real reads, not recollection"))
        #expect(text.contains("never \"line forty-two of"))
        #expect(text.contains("Sources/Session.swift:6"))
    }

    /// A traced turn is not small talk, whatever the router called it: the
    /// insight persona speaks and the conversational one stands down.
    @Test func aTracedTurnTakesTheInsightPersonaNotTheConverseOne() {
        let text = MaryPrompts.seerInstructions(
            liveWork: ["THE_LIVE_BLOCK"],
            liveWorkWorld: .document(name: "Xcode", whole: false),
            readPassages: ["func read() -> String { … }"],
            conversational: false,
            perceiving: true,
            awareness: ["- open — Sources/Session.swift:6: return reader.read()"])
        #expect(text.contains("they want your actual take"))
        #expect(!text.contains("This turn is CONVERSATION"))
    }

    // MARK: - When the runtime serves the pass

    /// THE SENTENCE THIS WHOLE PATH EXISTS FOR. The router scores "what do you
    /// think about this code" as CONVERSE about as often as perceive — so the
    /// pass has to earn its read on a converse turn: trace first, and read the
    /// unit only because the trace found something real.
    @Test func aConverseTurnEarnsItsReadByTracingFirst() async {
        let dispatched = Dispatched()
        let runtime = Self.runtime(dispatched: dispatched, surroundings: "Reached from:\n- open — S.swift:6: x")
        let route = Self.route(intent: .converse, deictic: true)
        let sight = await Self.underRoute(route) {
            await runtime.fetchAwareness(query: "what do you think about this code")
        }
        #expect(sight?.surroundings?.contains("Reached from:") == true)
        #expect(sight?.unit == "func read() -> String {\n    load()\n}")
        #expect(dispatched.snapshot() == ["trace_surroundings", "read_enclosing_unit"],
                "the trace comes first and the read is earned")
    }

    /// Nothing traced, nothing read: an idle remark in an editor stays an idle
    /// remark, and costs no Accessibility read at all.
    @Test func aConverseTurnThatTracesNothingReadsNothing() async {
        let dispatched = Dispatched()
        let runtime = Self.runtime(dispatched: dispatched, surroundings: nil)
        let route = Self.route(intent: .converse, deictic: true)
        let sight = await Self.underRoute(route) {
            await runtime.fetchAwareness(query: "how's your day going")
        }
        #expect(sight == nil)
        #expect(dispatched.snapshot() == ["trace_surroundings"])
    }

    /// A turn already about the work reads the unit first; the trace supports it.
    @Test func aPerceiveTurnReadsTheUnitFirst() async {
        let dispatched = Dispatched()
        let runtime = Self.runtime(dispatched: dispatched, surroundings: "Reached from:\n- open — S.swift:6: x")
        let route = Self.route(intent: .perceive, deictic: true)
        let sight = await Self.underRoute(route) {
            await runtime.fetchAwareness(query: "what does this function do")
        }
        #expect(sight?.unit?.contains("func read()") == true)
        #expect(dispatched.snapshot() == ["read_enclosing_unit", "trace_surroundings"])
    }

    /// A COMMAND IS NOT A QUESTION. An action turn has a receipt to deliver
    /// and no time to spend on bearings.
    @Test func anActionTurnIsLeftAlone() async {
        let dispatched = Dispatched()
        let runtime = Self.runtime(dispatched: dispatched, surroundings: "traced")
        let route = Self.route(intent: .operate, deictic: false)
        let sight = await Self.underRoute(route) {
            await runtime.fetchAwareness(query: "build the project")
        }
        #expect(sight == nil)
        #expect(dispatched.snapshot().isEmpty)
    }

    /// Plain conversation with nothing pointing at the work is left alone too,
    /// without even a trace: "this" is what makes a remark about their code.
    @Test func plainConversationIsNotTraced() async {
        let dispatched = Dispatched()
        let runtime = Self.runtime(dispatched: dispatched, surroundings: "traced")
        let route = Self.route(intent: .converse, deictic: false)
        let sight = await Self.underRoute(route) {
            await runtime.fetchAwareness(query: "thanks, that's great")
        }
        #expect(sight == nil)
        #expect(dispatched.snapshot().isEmpty)
    }

    /// No adapter declares the pair: nothing to ask, and no pretending.
    @Test func withoutAnAwarenessProviderNothingIsServed() async {
        let ambient = AmbientContextStore()
        let runtime = AbilityRuntime(
            plugins: [],
            world: AmbientWorld(store: ambient),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let sight = await Self.underRoute(Self.route(intent: .perceive, deictic: true)) {
            await runtime.fetchAwareness(query: "what do you think")
        }
        #expect(sight == nil)
    }

    // MARK: - The turn hands it to the voice

    /// END TO END: a converse-scored turn in an editor, and the voice pass
    /// carries the bearings and drops the small-talk persona.
    @Test func theTurnHandsTheBearingsToTheVoice() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [.init(events: [.token("Looks solid.")])])
        let engine = BrainFakes.ScriptedEngine(rounds: [.init(text: "NOOP")])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.awarenessSight = AwarenessSight(
            unit: "func read() -> String { load() }",
            surroundings: "Reached from:\n- open — Sources/Session.swift:6: reader.read()")
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)
        await brain.setSeerInstructionsProvider { pass in
            MaryPrompts.seerInstructions(
                liveWork: ["THE_LIVE_BLOCK"],
                liveWorkWorld: .document(name: "Xcode", whole: false),
                readPassages: pass.readPassages,
                conversational: pass.conversational,
                perceiving: pass.perceiving,
                awareness: pass.awareness)
        }

        for try await _ in brain.respond(to: "what do you think about this code") {}

        #expect(dispatcher.awarenessQueriesSnapshot() == ["what do you think about this code"])
        let instructions = try #require(seer.callsSnapshot().first?.instructions)
        #expect(instructions.contains("Sources/Session.swift:6"))
        #expect(instructions.contains("func read() -> String { load() }"))
        #expect(instructions.contains("I also traced this just now"))
        #expect(!instructions.contains("This turn is CONVERSATION"))
    }

    /// AND THE TURN THAT TRACED NOTHING IS UNTOUCHED — no bearings, and the
    /// router's own verdict stands.
    @Test func aTurnThatTracedNothingKeepsItsOwnVerdict() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [.init(events: [.token("Doing well!")])])
        let engine = BrainFakes.ScriptedEngine(rounds: [.init(text: "NOOP")])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.awarenessSight = nil
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)
        await brain.setSeerChat(seer)
        await brain.setSeerInstructionsProvider { pass in
            MaryPrompts.seerInstructions(
                conversational: pass.conversational,
                perceiving: pass.perceiving,
                awareness: pass.awareness)
        }

        for try await _ in brain.respond(to: "how's your day going") {}

        let instructions = try #require(seer.callsSnapshot().first?.instructions)
        #expect(!instructions.contains("I also traced this just now"))
    }

    // MARK: - Fixtures

    private final class Dispatched: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func note(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    /// An adapter declaring the awareness pair, answering scripted text.
    private struct AwarenessFixture: MaryAdapter {
        let name = "awareness"
        let summary = "A fixture."
        let dispatched: Dispatched
        let surroundings: String?

        var awarenessRead: AwarenessRead? {
            AwarenessRead(unit: "read_enclosing_unit", surroundings: "trace_surroundings")
        }

        var skillBindings: [SkillBinding] {
            let dispatched = dispatched
            let surroundings = surroundings
            return [
                SkillBinding(
                    name: "read_enclosing_unit",
                    description: "Read the unit.",
                    parameters: [],
                    access: .read,
                    backing: .native { _, _ in
                        dispatched.note("read_enclosing_unit")
                        return SkillOutcome(
                            ok: true, summary: "func read() -> String {\n    load()\n}")
                    }),
                SkillBinding(
                    name: "trace_surroundings",
                    description: "Trace what reaches it.",
                    parameters: [],
                    access: .read,
                    backing: .native { _, _ in
                        dispatched.note("trace_surroundings")
                        guard let surroundings else {
                            return SkillOutcome(
                                ok: true, summary: "Nothing reaches it.", foundNothing: true)
                        }
                        return SkillOutcome(ok: true, summary: surroundings)
                    }),
            ]
        }
    }

    private static func runtime(
        dispatched: Dispatched, surroundings: String?
    ) -> AbilityRuntime {
        AbilityRuntime(
            plugins: [AwarenessFixture(dispatched: dispatched, surroundings: surroundings)],
            world: AmbientWorld(store: AmbientContextStore()),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
    }

    private static func route(intent: AmbientIntent, deictic: Bool) -> AmbientRoute {
        AmbientRoute(
            intent: intent,
            decidedBy: .none,
            verdicts: AmbientVerdicts(isDeictic: deictic))
    }

    private static func underRoute<T>(
        _ route: AmbientRoute, _ body: () async -> T
    ) async -> T {
        let state = AmbientRouteTurnState()
        state.note(route)
        return await AmbientRouteTurnContext.$state.withValue(state) {
            await body()
        }
    }
}

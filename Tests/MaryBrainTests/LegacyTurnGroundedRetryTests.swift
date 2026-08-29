//
//  LegacyTurnGroundedRetryTests.swift
//  MaryBrainTests
//
//  The empty-round retry in `legacyTurn` (MaryBrain+LegacyTurn.swift) beat a
//  blank page for quantized local models by silently re-rolling the same
//  prompt. Live-reproduced on `--probe-chat` with Xcode genuinely frontmost:
//  a Skill ran, a real result landed in history, and the retry's blind
//  re-roll came back as ungrounded small talk ("Good evening… how was your
//  day?") — the model was never told a result was already sitting there.
//  `groundedRetryNudge` closes that gap by naming the result on the retry,
//  and ONLY on the retry, and ONLY when a real (landed, non-blocked,
//  non-parked, non-empty) result exists to ground on.
//
//  These pins verify the WIRING — the nudge lands in history at the right
//  moment under the right condition — not model behavior, which no fake
//  engine can stand in for.
//

import Foundation
import Testing
import MaryVoice
import MaryAmbient
import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct LegacyTurnGroundedRetryTests {

    private func call(_ name: String) -> ModelSkillInvocation {
        ModelSkillInvocation(id: UUID().uuidString, name: name, argumentsJSON: "{}")
    }

    private func collect(_ stream: AsyncThrowingStream<BrainEvent, Error>) async throws -> [BrainEvent] {
        var events: [BrainEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// A Skill lands a real result, the very next round is empty — the
    /// retry's request must carry `groundedRetryNudge` as its newest `user`
    /// turn, naming the result that is already in hand.
    @Test func emptyRoundAfterRealResultGetsGroundingNudge() async throws {
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),   // round 1: calls the Skill
            .init(),                          // round 2: empty — triggers retry
            .init(text: "Grounded answer."),  // round 3: the retry itself
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.results["probe"] = "the file's real content"
        // No seerChat configured — every turn takes the legacy path.
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let events = try await collect(brain.respond(to: "what does this file do"))
        #expect(events.contains {
            if case .completed(let text) = $0 { return text == "Grounded answer." }
            return false
        })

        let texts = engine.historyTextsSnapshot()
        #expect(texts.count == 3, "expected exactly one retry round: \(texts.count) requests")
        // The retry round (index 2) must see the nudge as its newest turn.
        #expect(texts[2].last == MaryBrain.groundedRetryNudge, "\(texts[2])")
        // The round that actually ran the Skill (index 1, seeing round 1's
        // history) must NOT have seen it — the nudge is added only after the
        // empty round is observed.
        #expect(!texts[1].contains(MaryBrain.groundedRetryNudge), "\(texts[1])")
    }

    /// The baseline the retry always had: a genuinely empty FIRST round, with
    /// nothing run yet, gets the same silent re-roll it always did — no
    /// nudge forced onto a turn that may simply be plain conversation.
    @Test func emptyFirstRoundGetsNoGroundingNudge() async throws {
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(),                    // round 1: empty, nothing has run
            .init(text: "Hello there."),
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        let events = try await collect(brain.respond(to: "hi"))
        #expect(events.contains {
            if case .completed(let text) = $0 { return text == "Hello there." }
            return false
        })

        let texts = engine.historyTextsSnapshot()
        #expect(texts.count == 2, "expected exactly one retry round: \(texts.count) requests")
        #expect(!texts[1].contains(MaryBrain.groundedRetryNudge), "\(texts[1])")
        // The pre-existing budget/confirm nudges are also absent — this is
        // the plain empty-round path, unchanged.
        #expect(!texts[1].contains(MaryBrain.budgetNudge), "\(texts[1])")
    }

    /// A Skill that ran but found nothing (`foundNothing`, `ok: true` by this
    /// codebase's own convention — "There's no code editor in front of me
    /// right now.") is not a real result to ground on; the retry must not
    /// claim one exists.
    @Test func foundNothingResultGetsNoGroundingNudge() async throws {
        let engine = BrainFakes.ScriptedEngine(rounds: [
            .init(calls: [call("probe")]),
            .init(),
            .init(text: "Anything I can help with?"),
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.results["probe"] = "nothing found"
        dispatcher.foundNothingTools = ["probe"]
        let brain = MaryBrain(engine: engine, dispatcher: dispatcher)

        _ = try await collect(brain.respond(to: "what does this file do"))

        let texts = engine.historyTextsSnapshot()
        #expect(texts.count == 3)
        #expect(!texts[2].contains(MaryBrain.groundedRetryNudge), "\(texts[2])")
    }
}

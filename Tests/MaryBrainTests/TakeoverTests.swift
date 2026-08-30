//
//  TakeoverTests.swift
//  MaryBrainTests
//
//  WHAT: Lane-A speech is a promise; retract once Lane B joins with outcomes.
//  OUT:  Takeover predicate and bounds
//  PIN:  Speaker mechanism lives in MaryVoice TakeoverTests
//

import MaryVoice
import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

@Suite struct TakeoverTests {

    private func call(_ name: String) -> ModelSkillInvocation {
        ModelSkillInvocation(id: UUID().uuidString, name: name, argumentsJSON: "{}")
    }

    private func collect(_ brain: MaryBrain, _ text: String) async throws -> [BrainEvent] {
        var events: [BrainEvent] = []
        for try await event in brain.respond(to: text) { events.append(event) }
        return events
    }

    private func fullText(_ events: [BrainEvent]) -> String? {
        for event in events { if case .completed(let text) = event { return text } }
        return nil
    }

    private func retracted(_ events: [BrainEvent]) -> Bool {
        events.contains { if case .retractSpeech = $0 { return true } else { return false } }
    }

    /// Two sentences — below the chunker's threshold, which is what makes it
    /// still-un-synthesized text when the lane joins. See
    /// `KokoroStreamSpeaker.sentencesBeforeFirstAudio`.
    private let acknowledgement = "On it. Putting that on now."

    /// A lane that dispatches one Skill and then ends.
    private func engineDispatching(_ skillName: String) -> BrainFakes.ScriptedEngine {
        BrainFakes.ScriptedEngine(rounds: [
            .init(text: "let me do that", calls: [call(skillName)]),
            .init(text: "NOOP"),
        ])
    }

    // MARK: - 1. The takeover fires

    /// "Put on some jazz" that the classifier did NOT catch: Lane A promises,
    /// the lane plays the music inside the grace, and the promise is retracted
    /// rather than left standing in front of the silence. The transcript and
    /// history keep what was written — the takeover rewinds the EAR.
    @Test func aCompletedFastActionRetractsItsAcknowledgement() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [
            .init(events: [.token(acknowledgement)]),
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.results["music_play"] = "playing Blue Train"
        let brain = MaryBrain(engine: engineDispatching("music_play"), dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let events = try await collect(brain, "some jazz would be good right now")
        #expect(retracted(events), "the stale promise was left to stand")
        #expect(fullText(events) == acknowledgement,
                "the takeover rewinds the ear, never the transcript")
    }

    // MARK: - 2. …and the five bounds it may not cross

    /// BOUND 3 — THE LANE REALLY ACTED. A read is not an action: "read me the
    /// part about batteries" runs a tool and gets a GENUINE conversational
    /// answer from Lane A, and silencing that is the reported bug in a new
    /// costume. `isReadOnly` is the same predicate that keeps reads out of Totem.
    @Test func aGenuineConversationalAnswerIsNotRetracted() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [
            .init(events: [.token("It says the batteries are the weak link. Worth a read.")]),
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.readOnlyTools = ["pages_body"]
        dispatcher.results["pages_body"] = "…batteries…"
        let brain = MaryBrain(engine: engineDispatching("pages_body"), dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let events = try await collect(brain, "what does it say about batteries")
        #expect(!retracted(events), "a read-only lane silenced a real answer")
    }

    /// …and a turn with NO Skills at all is untouched: pure conversation has
    /// nothing to be stale about.
    @Test func pureConversationIsNotRetracted() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [
            .init(events: [.token("I think so. It depends on the day.")]),
        ])
        let engine = BrainFakes.ScriptedEngine(rounds: [.init(text: "NOOP")])
        let brain = MaryBrain(engine: engine, dispatcher: BrainFakes.StubDispatcher())
        await brain.setSeerChat(seer)

        let events = try await collect(brain, "do you think thinking is async")
        #expect(!retracted(events))
    }

    /// BOUND 4a — AN UNRECOVERED FAILURE OWNS THE SENTENCE. The failure line is
    /// the correction; retracting the prose it corrects would leave the user
    /// with a bare complaint and no idea what was attempted.
    @Test func anUnrecoveredFailureIsNotRetracted() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [
            .init(events: [.token(acknowledgement)]),
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.failingTools = ["music_play"]
        dispatcher.results["music_play"] = "Music isn't running"
        let brain = MaryBrain(engine: engineDispatching("music_play"), dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let events = try await collect(brain, "some jazz would be good right now")
        #expect(!retracted(events))
        #expect(fullText(events)?.contains("didn't go through") == true)
    }

    /// BOUND 4b — A DEFERRED SPAWN IS THE ONE CASE WHERE "I'm on it" IS TRUE.
    /// The ack is a fire-and-forget start, not a finished result; the real
    /// outcome arrives later on another channel, and retracting the only
    /// sentence that said work had begun would leave the start unannounced.
    @Test func aDeferredSpawnIsNotRetracted() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [
            .init(events: [.token(acknowledgement)]),
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.deferredTools = ["delegate_coding"]
        dispatcher.results["delegate_coding"] = "Claude's on it"
        let brain = MaryBrain(
            engine: engineDispatching("delegate_coding"), dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let events = try await collect(brain, "have claude fix the build")
        #expect(!retracted(events))
    }

    /// BOUND 4c — A SURFACED CONFIRM OUTRANKS IT. A question the user has to
    /// answer beats a report about what already happened, and nothing has run.
    @Test func aSurfacedConfirmIsNotRetracted() async throws {
        let seer = BrainFakes.ScriptedSeer(scripts: [
            .init(events: [.token(acknowledgement)]),
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.results["delete_file"] = "CONFIRM: Really delete it?"
        let brain = MaryBrain(engine: engineDispatching("delete_file"), dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let events = try await collect(brain, "the old draft should probably go")
        #expect(!retracted(events))
        #expect(fullText(events)?.contains("Really delete it?") == true)
    }

    /// BOUND 5 — IT CANNOT ALREADY BE AUDIBLE. Three sentences have handed a
    /// batch to synthesis, so the user is already listening to a real answer;
    /// cutting a reply off mid-flow is worse than the stale sentence the
    /// takeover exists to remove. The judgement is the CHUNKER's, not a second
    /// copy of its arithmetic living in the brain.
    @Test func anAnswerThatIsAlreadyAudibleIsNotRetracted() async throws {
        let long = "One thing is happening. Two things are happening. Three are too."
        #expect(KokoroStreamSpeaker.mayAlreadyBeAudible(long),
                "the fixture must be past the threshold or this test proves nothing")
        #expect(!KokoroStreamSpeaker.mayAlreadyBeAudible(acknowledgement),
                "…and the short one must be below it")

        let seer = BrainFakes.ScriptedSeer(scripts: [.init(events: [.token(long)])])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.results["music_play"] = "playing Blue Train"
        let brain = MaryBrain(engine: engineDispatching("music_play"), dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let events = try await collect(brain, "tell me about jazz and put some on")
        #expect(!retracted(events))
    }

    /// BOUND 1 — A STALLED LANE AND A DROPPED CONNECTION HAVE JUST SPOKEN
    /// HONEST LINES ABOUT THEMSELVES. Silencing an apology for silence is
    /// absurd, and the Seer-drop notice is the only thing telling the user the
    /// reply is a fragment.
    @Test func aDroppedSeerConnectionIsNotRetracted() async throws {
        struct Dropped: Error {}
        let seer = BrainFakes.ScriptedSeer(scripts: [
            .init(events: [.token("Partial thought")], error: Dropped()),
        ])
        let dispatcher = BrainFakes.StubDispatcher()
        dispatcher.results["music_play"] = "playing Blue Train"
        let brain = MaryBrain(engine: engineDispatching("music_play"), dispatcher: dispatcher)
        await brain.setSeerChat(seer)

        let events = try await collect(brain, "some jazz would be good right now")
        #expect(!retracted(events))
        #expect(fullText(events)?.contains("the Seer connection dropped") == true)
    }

    // MARK: - 3. The window is one window

    /// The speaker holds synthesis for exactly as long as the brain holds the
    /// turn for its lane. Two numbers describing one window drift apart in
    /// silence unless something says they are the same window.
    @Test func theSpeakerHoldMatchesTheLaneJoinGrace() {
        #expect(KokoroStreamSpeaker.takeoverHoldNanoseconds
                == MaryBrain.laneJoinGraceNanoseconds)
    }

    // MARK: - 4. A dropped progress mark books a row

    /// THE FAILURE THIS MAKES VISIBLE: `VoicePipeline.speakRoutineProgress` is a
    /// hard, silent, ONE-SHOT gate. A mark that fires while the user is
    /// mid-utterance is consumed forever — no retry, no trace — so a routine
    /// that loses both marks can sit silent from 0 to 420 s with nothing
    /// anywhere recording that two spoken promises were destroyed. The user
    /// accepted the drop; the invisibility was never part of that.
    @Test func aDroppedProgressMarkBooksALedgerRow() async {
        let ledger = ReadDeliveryLedger()
        let brain = MaryBrain(
            engine: BrainFakes.ScriptedEngine(rounds: []),
            dispatcher: BrainFakes.StubDispatcher())
        await brain.setReadLedgerForTesting(ledger)

        await brain.noteProgressDropped("Still working on the Purpose section — I'll tell you the moment it lands.")

        let row = ledger.latest()
        #expect(row?.route == .droppedStale)
        #expect(row?.detail.hasPrefix("progress mark — ") == true, "\(row?.detail ?? "nil")")
        #expect(ReadRoute.failures.contains(.droppedStale),
                "a mark nobody heard is a delivery failure, not a success")
    }
}

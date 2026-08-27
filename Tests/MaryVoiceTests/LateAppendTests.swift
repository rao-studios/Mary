//
//  LateAppendTests.swift
//  MaryVoiceTests
//
//  The reported defect, pinned: "when I talk after some time then the result
//  pipes in later and appends to the response that answered the new query."
//  Three of its confirmed mechanisms live in MaryVoice —
//
//    1. the barge-in onset stayed 3× boosted while NOTHING was playing, so
//       normal-volume speech was swallowed and the held reply arrived late;
//    2. `feed` is a length-diffing API, so a superseded turn resuming on a
//       foreign baseline spliced a suffix of ITS passage into the live stream;
//    3. `followUpBuffer` was origin-blind, so a follow-up narrating an older
//       exchange cut into a newer reply at a sentence boundary.
//
//  Driven through the internal seams — a real session needs a mic and a human.
//

import AVFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct LateAppendTests {

    // MARK: - Scripted collaborators

    private final class SilentResponder: LanguageResponder, @unchecked Sendable {
        func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func cancel() async {}
    }

    private final class StubTranscriber: VoiceTranscriber, @unchecked Sendable {
        func begin(format: AVAudioFormat) async throws {}
        func append(_ buffer: AVAudioPCMBuffer) async {}
        func partials() async -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func finish() async throws -> String { "" }
        func cancel() async {}
    }

    private func makePipeline() -> VoicePipeline {
        VoicePipeline(
            config: VoicePipelineConfig(),
            transcriber: StubTranscriber(),
            speaker: KokoroStreamSpeaker(synthesizer: LateAppendNullSynthesizer()),
            responder: SilentResponder())
    }

    private func makeSpeaker() -> KokoroStreamSpeaker {
        KokoroStreamSpeaker(synthesizer: LateAppendNullSynthesizer())
    }

    /// Collects .chunkQueued text until cancelled (pre-engine, headless-safe —
    /// same posture as SpeechRouterTests).
    private func chunkCollector(_ events: AsyncStream<SpeakerEvent>) -> Task<[String], Never> {
        Task {
            var chunks: [String] = []
            for await event in events {
                if case .chunkQueued(let text) = event { chunks.append(text) }
            }
            return chunks
        }
    }

    // MARK: - 1. The mic is not deafened while nothing is playing

    @Test func boostedOnsetDemotesWhenTheSpeakerGoesQuiet() async {
        let pipeline = makePipeline()
        let config = VADConfig()
        let boosted = config.speechStartRMS * config.bargeInRMSBoost

        await pipeline.handleSpeakerEventForTesting(.started)
        var onset = await pipeline.bargeInOnsetForTesting
        #expect(onset == boosted, "her own voice is in the room — guard against it")

        // The turn stays open (a tool call, a slow lane) with the audio played
        // out. `.speaking` outlives the sound; the boost must not.
        await pipeline.handleSpeakerEventForTesting(.audioIdle)
        onset = await pipeline.bargeInOnsetForTesting
        #expect(onset == config.speechStartRMS,
                "silent-but-thinking must be interruptible at normal volume")

        // Audio queues again — re-armed BEFORE it becomes audible.
        await pipeline.handleSpeakerEventForTesting(.chunkScheduled("Next sentence."))
        onset = await pipeline.bargeInOnsetForTesting
        #expect(onset == boosted)
    }

    @Test func endOfPlaybackAlsoDemotes() async {
        let pipeline = makePipeline()
        let config = VADConfig()

        await pipeline.handleSpeakerEventForTesting(.started)
        await pipeline.handleSpeakerEventForTesting(.drained)
        var onset = await pipeline.bargeInOnsetForTesting
        #expect(onset == config.speechStartRMS)

        await pipeline.handleSpeakerEventForTesting(.started)
        await pipeline.handleSpeakerEventForTesting(.stopped)
        onset = await pipeline.bargeInOnsetForTesting
        #expect(onset == config.speechStartRMS)
    }

    @Test func aProvisionalPauseKeepsTheBoostedCadence() async {
        // `.paused` is the barge-in onset itself — demoting there would rebuild
        // the governor mid-decision and lose the pause/resume cadence.
        let pipeline = makePipeline()
        let config = VADConfig()

        await pipeline.handleSpeakerEventForTesting(.started)
        await pipeline.handleSpeakerEventForTesting(.paused)
        let onset = await pipeline.bargeInOnsetForTesting
        #expect(onset == config.speechStartRMS * config.bargeInRMSBoost)
    }

    // MARK: - 2. A foreign baseline resets; it never splices

    @Test func foreignBaselineResetsInsteadOfSplicing() async {
        let speaker = makeSpeaker()
        let collector = chunkCollector(await speaker.events())

        // Writer B — the turn that answered the NEW query — owns the floor.
        await speaker.feed("Sure, here is the short answer. ")
        // Writer A — the SUPERSEDED turn, resuming from its own `accumulated`
        // after the actor hop. Its string does not extend B's baseline, so it
        // is not a delta: it is a different passage entirely.
        await speaker.feed(
            "Turn N was reading a long passage aloud and it ended on the word marmalade. ")
        // B keeps streaming and re-synchronizes on its next growing feed.
        await speaker.feed("Sure, here is the short answer. Second sentence lands. ")
        await speaker.feed(
            "Sure, here is the short answer. Second sentence lands. Third one too. Fourth begins")
        await speaker.flush()

        collector.cancel()
        let spoken = await collector.value.joined(separator: " ")
        #expect(!spoken.contains("marmalade"),
                "turn N's passage must never enter turn N+1's stream")
        #expect(!spoken.contains("Turn N was reading"))
        #expect(spoken.contains("Sure, here is the short answer."),
                "the rightful writer keeps the floor")
    }

    @Test func aFreshWriterAfterAStopStillSpeaks() async {
        // The reset must not deafen the NEXT legitimate turn: hardStop clears
        // the baseline to "", and every string has "" as a prefix.
        let speaker = makeSpeaker()
        let collector = chunkCollector(await speaker.events())

        await speaker.feed("Interrupted mid thought and never finished")
        await speaker.hardStop()
        await speaker.feed("A brand new reply. It speaks normally. Trailing")
        await speaker.flush()

        collector.cancel()
        let spoken = await collector.value.joined(separator: " ")
        #expect(spoken.contains("A brand new reply."))
        #expect(!spoken.contains("Interrupted mid thought"),
                "hardStop dropped the stopped writer's buffer with its baseline")
    }

    // MARK: - 3. A stale-origin follow-up waits for quiet; it never cuts in

    @Test func staleOriginFollowUpNeverCutsIntoANewerReply() async {
        let pipeline = makePipeline()
        let older = UUID(), current = UUID()
        await pipeline.setCurrentUserTurnIDForTesting(current)

        // The newer reply is draining — exactly the (.speaking, false) cut
        // path that glued turn N's read onto turn N+1's answer.
        await pipeline.setStateForTesting(.speaking)
        await pipeline.setGenerationActiveForTesting(false)
        await pipeline.handleProactive(
            .followUpToken("The passage you asked about earlier. ", originUserTurnID: older))

        let speaking = await pipeline.isFollowUpSpeaking
        #expect(!speaking, "older narration may not cut into a newer reply")
        let buffered = await pipeline.followUpBufferForTesting
        #expect(!buffered.isEmpty, "it waits — playFollowUpWhenQuiet is its only route")
    }

    @Test func staleOriginFollowUpNeverPreemptsAGeneratingTurn() async {
        let pipeline = makePipeline()
        let older = UUID(), current = UUID()
        await pipeline.setCurrentUserTurnIDForTesting(current)

        await pipeline.setStateForTesting(.thinking)
        await pipeline.setGenerationActiveForTesting(true)
        await pipeline.handleProactive(
            .followUpToken("Old news. ", originUserTurnID: older))

        let speaking = await pipeline.isFollowUpSpeaking
        #expect(!speaking, "the newer turn is not cancelled for older narration")
    }

    @Test func staleOriginStillSpeaksIntoAQuietRoom() async {
        // Quiet is quiet: the origin gate blocks the CUT, not the follow-up.
        let pipeline = makePipeline()
        await pipeline.setCurrentUserTurnIDForTesting(UUID())

        await pipeline.setStateForTesting(.listening(utteranceActive: false))
        await pipeline.handleProactive(
            .followUpToken("Finally, about that passage. ", originUserTurnID: UUID()))

        let speaking = await pipeline.isFollowUpSpeaking
        #expect(speaking)
    }

    @Test func theCurrentTurnsOwnFollowUpStillTakesTheFloor() async {
        let pipeline = makePipeline()
        let current = UUID()
        await pipeline.setCurrentUserTurnIDForTesting(current)

        await pipeline.setStateForTesting(.speaking)
        await pipeline.setGenerationActiveForTesting(false)
        await pipeline.handleProactive(
            .followUpToken("The deeper answer to what you just asked. ",
                           originUserTurnID: current))

        let speaking = await pipeline.isFollowUpSpeaking
        #expect(speaking, "narration OF the exchange on screen still preempts")
    }

    @Test func standaloneNoticeIsNeverStale() async {
        // nil origin = the coding bridge's "that change didn't go through".
        // It belongs to no exchange, so it cannot be about an older one.
        let pipeline = makePipeline()
        await pipeline.setCurrentUserTurnIDForTesting(UUID())

        await pipeline.setStateForTesting(.speaking)
        await pipeline.setGenerationActiveForTesting(false)
        await pipeline.handleProactive(
            .followUpToken("Heads up — that change failed. ", originUserTurnID: nil))

        let speaking = await pipeline.isFollowUpSpeaking
        #expect(speaking)
    }

    @Test func aCancelledRoutinesBufferAndOriginClearTogether() async {
        let pipeline = makePipeline()
        let origin = UUID()
        await pipeline.setStateForTesting(.transcribing)   // user holds the floor
        await pipeline.handleProactive(.followUpToken("Half a thought. ", originUserTurnID: origin))
        let buffered = await pipeline.followUpBufferForTesting
        #expect(!buffered.isEmpty)

        await pipeline.handleProactive(
            .routineCancelled(acknowledgement: "stopped", originUserTurnID: origin))

        let after = await pipeline.followUpBufferForTesting
        #expect(after.isEmpty)
    }
}

private actor LateAppendNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

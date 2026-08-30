//
//  LateAppendTests.swift
//  MaryVoiceTests
//
//  WHAT: Three splice bugs that append a stale reply into a live stream.
//  OUT:  VoicePipeline barge-in onset, KokoroStreamSpeaker.feed, follow-up origin
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

}

private actor LateAppendNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

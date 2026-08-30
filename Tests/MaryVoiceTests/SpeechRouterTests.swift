//
//  SpeechRouterTests.swift
//  MaryVoiceTests
//
//  WHAT: Server tokens stay transcript-only; baseline advances only on played audio.
//  OUT:  SpeechRouter via .chunkQueued
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct SpeechRouterTests {

    private func makeSpeaker() -> KokoroStreamSpeaker {
        KokoroStreamSpeaker(synthesizer: RouterNullSynthesizer())
    }

    /// Collects .chunkQueued text seen on `events` until cancelled.
    private func chunkCollector(_ events: AsyncStream<SpeakerEvent>) -> Task<[String], Never> {
        Task {
            var chunks: [String] = []
            for await event in events {
                if case .chunkQueued(let text) = event { chunks.append(text) }
            }
            return chunks
        }
    }

    private func silentPCM() -> Data {
        Data(count: 240 * MemoryLayout<Float32>.size)
    }

    @Test func serverTokensNeverFeedTheSpeaker() async {
        let speaker = makeSpeaker()
        let events = await speaker.events()
        let collector = chunkCollector(events)

        var router = SpeechRouter(speaker: speaker)
        router.consumeSpeechSource(.server, accumulated: "")
        await router.consumeToken(accumulated: "Server voiced sentence one. ")
        await router.consumeAudioChunk(silentPCM(), sampleRate: 24_000)
        await router.consumeToken(accumulated: "Server voiced sentence one. And two.")
        await router.finish()

        #expect(router.didUseRemoteAudio)
        #expect(!router.didFeedSpeaker)
        collector.cancel()
        let chunks = await collector.value
        #expect(chunks.isEmpty)
    }

    @Test func baselineSkipsServerVoicedTextAfterAudio() async {
        let speaker = makeSpeaker()
        let events = await speaker.events()
        let collector = chunkCollector(events)

        var router = SpeechRouter(speaker: speaker)
        router.consumeSpeechSource(.server, accumulated: "")
        var accumulated = "Server said this already. "
        await router.consumeToken(accumulated: accumulated)
        await router.consumeAudioChunk(silentPCM(), sampleRate: 24_000)
        router.consumeSpeechSource(.local, accumulated: accumulated)
        accumulated += "Local tail speaks now."
        await router.consumeToken(accumulated: accumulated)
        await router.finish()

        #expect(router.didFeedSpeaker)
        collector.cancel()
        let spoken = await collector.value.joined(separator: " ")
        #expect(spoken.contains("Local tail speaks now."))
        #expect(!spoken.contains("Server said this already."))
    }

    @Test func withoutRemoteAudioLocalSpeaksFromTheTop() async {
        let speaker = makeSpeaker()
        let events = await speaker.events()
        let collector = chunkCollector(events)

        var router = SpeechRouter(speaker: speaker)
        router.consumeSpeechSource(.server, accumulated: "")
        var accumulated = "Never actually voiced by the server. "
        await router.consumeToken(accumulated: accumulated)
        // No audio ever arrived — the hand-back must NOT advance the baseline.
        router.consumeSpeechSource(.local, accumulated: accumulated)
        accumulated += "And the rest."
        await router.consumeToken(accumulated: accumulated)
        await router.finish()

        collector.cancel()
        let spoken = await collector.value.joined(separator: " ")
        #expect(spoken.contains("Never actually voiced by the server."))
        #expect(spoken.contains("And the rest."))
    }

    @Test func localOnlyTurnFlushes() async {
        let speaker = makeSpeaker()
        let events = await speaker.events()
        let collector = chunkCollector(events)

        var router = SpeechRouter(speaker: speaker)
        await router.consumeToken(accumulated: "Plain local reply")
        await router.finish()

        #expect(router.didFeedSpeaker)
        #expect(!router.didUseRemoteAudio)
        collector.cancel()
        let chunks = await collector.value
        #expect(chunks.joined().contains("Plain local reply"))
    }
}

private actor RouterNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

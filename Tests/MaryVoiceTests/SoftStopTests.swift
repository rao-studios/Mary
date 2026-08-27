//
//  SoftStopTests.swift
//  MaryVoiceTests
//
//  The sentence-boundary stop: must always RETURN (never wedge), reset text
//  ingest, and leave the speaker usable for the next utterance. Playback
//  assertions stay tolerant — headless runners may lack a startable
//  AVAudioEngine (same posture as RemoteAudioTests).
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct SoftStopTests {

    private func makeSpeaker() -> KokoroStreamSpeaker {
        KokoroStreamSpeaker(synthesizer: SoftStopNullSynthesizer())
    }

    private func silentPCM(seconds: Double) -> Data {
        Data(count: Int(24_000 * seconds) * MemoryLayout<Float32>.size)
    }

    @Test func softStopIdleReturnsImmediatelyAndResetsIngest() async {
        let speaker = makeSpeaker()
        let events = await speaker.events()
        let collector = Task {
            var chunks: [String] = []
            for await event in events {
                if case .chunkQueued(let text) = event { chunks.append(text) }
            }
            return chunks
        }

        await speaker.feed("Half a sentence with no end yet")
        await speaker.softStop()            // must return without playback
        // Fresh utterance after the stop queues ONLY fresh text.
        await speaker.feed("Fresh start. And more!")
        await speaker.flush()

        collector.cancel()
        let chunks = await collector.value.joined(separator: " ")
        #expect(chunks.contains("Fresh start."))
        #expect(!chunks.contains("Half a sentence"))
    }

    @Test func softStopDuringRemotePlaybackReturnsAndAllowsFreshCycle() async {
        let speaker = makeSpeaker()
        await speaker.beginRemoteAudio()
        // Enough audio that scheduled buffers are still playing when we cut.
        await speaker.enqueueRemotePCM(silentPCM(seconds: 2.0), sampleRate: 24_000)
        await speaker.enqueueRemotePCM(silentPCM(seconds: 2.0), sampleRate: 24_000)
        try? await Task.sleep(nanoseconds: 150_000_000)   // let playback arm

        await speaker.softStop()            // the pin: returns at the boundary

        // Speaker is reusable immediately.
        await speaker.beginRemoteAudio()
        await speaker.enqueueRemotePCM(silentPCM(seconds: 0.01), sampleRate: 24_000)
        await speaker.endRemoteAudio()
        let paused = await speaker.isPaused
        #expect(!paused)
    }

    @Test func flushAfterSoftStopDoesNotWedge() async {
        let speaker = makeSpeaker()
        await speaker.feed("One complete sentence here. And ")
        await speaker.softStop()
        await speaker.flush()               // must return promptly
        await speaker.hardStop()            // and hardStop stays safe after
        let paused = await speaker.isPaused
        #expect(!paused)
    }

    @Test func hardStopReleasesAPendingSoftStopWaiter() async {
        let speaker = makeSpeaker()
        await speaker.beginRemoteAudio()
        await speaker.enqueueRemotePCM(silentPCM(seconds: 3.0), sampleRate: 24_000)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let softStopTask = Task { await speaker.softStop() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await speaker.hardStop()            // barge-in racing the soft stop
        await softStopTask.value            // must not hang
        #expect(Bool(true))
    }
}

private actor SoftStopNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] {
        // Short real waveform so playback paths engage when an engine exists.
        [Float](repeating: 0, count: 240)
    }
}

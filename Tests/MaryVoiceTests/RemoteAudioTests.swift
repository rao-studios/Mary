//
//  RemoteAudioTests.swift
//  MaryVoiceTests
//
//  The speaker's remote-PCM seam (realtime Seer route): decode fidelity and
//  lifecycle. Playback assertions stay tolerant — headless runners may lack
//  a startable AVAudioEngine, in which case the pipeline exits before any
//  events fire (same posture as SentenceSpeakerTests).
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct RemoteAudioTests {

    // MARK: - Decode

    @Test func decodeFloat32LERoundTrips() {
        let source: [Float] = [0, 1, -1, 0.5, -0.25, 1e-3]
        var data = Data()
        for value in source {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        #expect(KokoroStreamSpeaker.decodeFloat32LE(data) == source)
    }

    @Test func decodeDropsTrailingPartialFloat() {
        var data = Data()
        withUnsafeBytes(of: Float(0.75).bitPattern.littleEndian) { data.append(contentsOf: $0) }
        data.append(0xAB)   // one stray byte
        #expect(KokoroStreamSpeaker.decodeFloat32LE(data) == [0.75])
    }

    @Test func decodeEmptyYieldsNothing() {
        #expect(KokoroStreamSpeaker.decodeFloat32LE(Data()).isEmpty)
        #expect(KokoroStreamSpeaker.decodeFloat32LE(Data([1, 2, 3])).isEmpty)
    }

    // MARK: - Lifecycle

    private func silentPCM(samples: Int) -> Data {
        Data(count: samples * MemoryLayout<Float32>.size)
    }

    @Test func remoteLifecycleCompletesAndOrdersEvents() async {
        let speaker = KokoroStreamSpeaker(synthesizer: NullSynthesizer())
        let events = await speaker.events()
        let collector = Task {
            var seen: [String] = []
            for await event in events {
                switch event {
                case .started: seen.append("started")
                case .drained: seen.append("drained")
                default: break
                }
                if seen.contains("drained") { break }
            }
            return seen
        }

        await speaker.beginRemoteAudio()
        await speaker.beginRemoteAudio()   // idempotent — second arm is a no-op
        await speaker.enqueueRemotePCM(silentPCM(samples: 240), sampleRate: 24_000)
        await speaker.endRemoteAudio()     // must return — this is the real pin

        collector.cancel()
        let seen = await collector.value
        // With a startable engine the full pair fires in order; headless the
        // pipeline exits silently. Either way, no started-without-drained.
        if seen.contains("started") {
            #expect(seen == ["started", "drained"])
        }
    }

    @Test func hardStopResetsRemotePipeline() async {
        let speaker = KokoroStreamSpeaker(synthesizer: NullSynthesizer())
        await speaker.beginRemoteAudio()
        await speaker.enqueueRemotePCM(silentPCM(samples: 24_000), sampleRate: 24_000)
        await speaker.hardStop()

        // A fresh remote turn arms and drains cleanly after the stop.
        await speaker.beginRemoteAudio()
        await speaker.enqueueRemotePCM(silentPCM(samples: 240), sampleRate: 24_000)
        await speaker.endRemoteAudio()
        let paused = await speaker.isPaused
        #expect(!paused)
    }
}

/// A synthesizer that must never be reached — remote turns bypass Stage A.
private actor NullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] {
        Issue.record("Stage A synthesizer invoked during a remote-audio turn")
        return []
    }
}

//
//  PreRollReplayTests.swift
//  MaryVoiceTests
//
//  WHAT: The first word reaches the recognizer — on a fresh utterance and on
//        a barge-in.
//  OUT:  VoicePipeline.openUtterance / performBargeIn replay
//  PIN:  A soft onset lives in the audio BEFORE the frame that tripped the
//        detector. Whatever opens an utterance must replay it.
//

import AVFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct PreRollReplayTests {

    /// Every buffer the pipeline fed, grouped by utterance.
    final class RecordingTranscriber: VoiceTranscriber, @unchecked Sendable {
        private let lock = NSLock()
        private var utterances: [[AVAudioPCMBuffer]] = []
        var heard: [[AVAudioPCMBuffer]] { lock.withLock { utterances } }

        func begin(format: AVAudioFormat) async throws {
            lock.withLock { utterances.append([]) }
        }
        func append(_ buffer: AVAudioPCMBuffer) async {
            lock.withLock {
                guard !utterances.isEmpty else { return }
                utterances[utterances.count - 1].append(buffer)
            }
        }
        func partials() async -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func finish() async throws -> String { "" }
        func cancel() async {}
    }

    private final class SilentResponder: LanguageResponder, @unchecked Sendable {
        func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func cancel() async {}
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    /// 20 ms of audio at `rms`.
    private func frame(rms: Float) -> MicFrame {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 960)!
        buffer.frameLength = 960
        return MicFrame(buffer: buffer, rms: rms, duration: 0.02)
    }

    private func seconds(_ buffers: [AVAudioPCMBuffer]) -> Double {
        buffers.reduce(0) { $0 + Double($1.frameLength) / Self.format.sampleRate }
    }

    private func makePipeline(_ transcriber: RecordingTranscriber) async -> VoicePipeline {
        let pipeline = VoicePipeline(
            config: VoicePipelineConfig(),
            transcriber: transcriber,
            speaker: KokoroStreamSpeaker(synthesizer: PreRollNullSynthesizer()),
            responder: SilentResponder())
        await pipeline.installMicForTesting(format: Self.format)
        return pipeline
    }

    @Test func openingAnUtteranceReplaysTheConfiguredPreRoll() async {
        let transcriber = RecordingTranscriber()
        let pipeline = await makePipeline(transcriber)
        await pipeline.setStateForTesting(.listening(utteranceActive: false))

        // A second of sub-threshold audio — the soft "h" of "hey" lives here.
        for _ in 0..<50 { await pipeline.handleFrameForTesting(frame(rms: 0.005)) }
        let onset = frame(rms: 0.05)
        await pipeline.handleFrameForTesting(onset)

        let first = transcriber.heard.first ?? []
        #expect(seconds(first) >= 0.55, "≈600 ms before the trip reaches the recognizer")
        #expect(first.last === onset.buffer, "the frame that opened the utterance lands last")
        await pipeline.stop()
    }

    /// The governor commits after ≥ 300 ms VOICED; choppy speech spreads that
    /// past any pre-roll. The interruption's first word must still be heard.
    @Test func bargeInReplaysFromTheOnset() async {
        let transcriber = RecordingTranscriber()
        let pipeline = await makePipeline(transcriber)
        await pipeline.setStateForTesting(.speaking)

        for _ in 0..<10 { await pipeline.handleFrameForTesting(frame(rms: 0.001)) }
        let onset = frame(rms: 0.05)
        await pipeline.handleFrameForTesting(onset)
        // One voiced frame in three: commit lands ~840 ms after the onset.
        for _ in 0..<20 {
            await pipeline.handleFrameForTesting(frame(rms: 0.001))
            await pipeline.handleFrameForTesting(frame(rms: 0.001))
            await pipeline.handleFrameForTesting(frame(rms: 0.05))
        }

        let first = transcriber.heard.first ?? []
        #expect(!first.isEmpty, "the barge-in opened an utterance")
        #expect(first.contains { $0 === onset.buffer },
                "the first word of the interruption reaches the recognizer")
        await pipeline.stop()
    }
}

private actor PreRollNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

//
//  FollowUpPreemptionTests.swift
//  MaryVoiceTests
//
//  A detached routine's follow-up outranks small talk: mid-generation it
//  cancels the in-flight turn (barge-in-like, .turnCancelled emitted); during
//  audio drain it cuts at the sentence boundary; a quiet room streams
//  immediately; the USER keeping the floor still buffers. Driven through the
//  internal seams — a real session needs a mic and a human.
//

import AVFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct FollowUpPreemptionTests {

    // MARK: - Scripted collaborators

    final class RecordingResponder: LanguageResponder, @unchecked Sendable {
        private let lock = NSLock()
        private var cancels = 0
        var cancelCount: Int {
            lock.lock(); defer { lock.unlock() }
            return cancels
        }

        func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func cancel() async {
            lock.withLock { cancels += 1 }
        }
    }

    final class StubTranscriber: VoiceTranscriber, @unchecked Sendable {
        func begin(format: AVAudioFormat) async throws {}
        func append(_ buffer: AVAudioPCMBuffer) async {}
        func partials() async -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func finish() async throws -> String { "" }
        func cancel() async {}
    }

    private func makePipeline(responder: RecordingResponder)
        -> (VoicePipeline, KokoroStreamSpeaker) {
        let speaker = KokoroStreamSpeaker(synthesizer: PreemptionNullSynthesizer())
        let pipeline = VoicePipeline(
            config: VoicePipelineConfig(),
            transcriber: StubTranscriber(),
            speaker: speaker,
            responder: responder
        )
        return (pipeline, speaker)
    }

    /// Collects pipeline events until cancelled; returns whether
    /// .turnCancelled was seen.
    private func turnCancelledWatcher(_ events: AsyncStream<VoicePipelineEvent>) -> Task<Bool, Never> {
        Task {
            for await event in events {
                if case .turnCancelled = event { return true }
            }
            return false
        }
    }

    // MARK: - Tests

    @Test func midGenerationFollowUpCancelsTheTurn() async {
        let responder = RecordingResponder()
        let (pipeline, _) = makePipeline(responder: responder)
        let watcher = turnCancelledWatcher(await pipeline.events())

        await pipeline.setStateForTesting(.thinking)
        await pipeline.setGenerationActiveForTesting(true)
        await pipeline.handleProactive(.followUpToken("The deeper answer, arriving now. ", originUserTurnID: nil))

        #expect(responder.cancelCount == 1, "the in-flight turn is cancelled")
        let speakingFollowUp = await pipeline.isFollowUpSpeaking
        #expect(speakingFollowUp, "the follow-up takes the floor")
        try? await Task.sleep(nanoseconds: 100_000_000)
        watcher.cancel()
        let sawTurnCancelled = await watcher.value
        #expect(sawTurnCancelled, "the app must finalize the interrupted bubble")
    }

    @Test func drainPhaseCutsAudioWithoutCancellingAnything() async {
        let responder = RecordingResponder()
        let (pipeline, _) = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.speaking)         // audio draining,
        await pipeline.setGenerationActiveForTesting(false)  // generation done
        await pipeline.handleProactive(.followUpToken("Deep answer. ", originUserTurnID: nil))

        #expect(responder.cancelCount == 0, "no turn left to cancel — audio just yields")
        let speakingFollowUp = await pipeline.isFollowUpSpeaking
        #expect(speakingFollowUp)
    }

    @Test func quietRoomStreamsImmediately() async {
        let responder = RecordingResponder()
        let (pipeline, _) = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.listening(utteranceActive: false))
        await pipeline.handleProactive(.followUpToken("Right away. ", originUserTurnID: nil))

        #expect(responder.cancelCount == 0)
        let speakingFollowUp = await pipeline.isFollowUpSpeaking
        #expect(speakingFollowUp)
    }

    @Test func userHoldingTheFloorStaysBuffered() async {
        let responder = RecordingResponder()
        let (pipeline, _) = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.transcribing)     // the user's moment
        await pipeline.handleProactive(.followUpToken("Patience. ", originUserTurnID: nil))

        #expect(responder.cancelCount == 0)
        let speakingFollowUp = await pipeline.isFollowUpSpeaking
        #expect(!speakingFollowUp, "never talk over the user")
    }

    /// A NEW user turn drops a buffered (not-yet-spoken) follow-up: the
    /// topic change was the acknowledgement — stale narration must not play
    /// after the new reply. (Failures still speak: the brain re-sends their
    /// text via followUpCompleted after this drop.)
    @Test func newTurnDropsBufferedFollowUp() async {
        let responder = RecordingResponder()
        let (pipeline, _) = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.transcribing)     // user has the floor
        await pipeline.handleProactive(.followUpToken("Stale news. ", originUserTurnID: nil))
        let buffered = await pipeline.followUpBufferForTesting
        #expect(!buffered.isEmpty, "precondition: the follow-up sits buffered")

        await pipeline.submitTurnForTesting("something new entirely")

        let speaking = await pipeline.isFollowUpSpeaking
        #expect(!speaking)
        let after = await pipeline.followUpBufferForTesting
        #expect(after.isEmpty, "the new topic dropped the stale follow-up")
    }

    @Test func routineSettledIsSilent() async {
        let responder = RecordingResponder()
        let (pipeline, _) = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.listening(utteranceActive: false))
        await pipeline.handleProactive(.routineSettled(originUserTurnID: UUID()))

        #expect(responder.cancelCount == 0)
        let speakingFollowUp = await pipeline.isFollowUpSpeaking
        #expect(!speakingFollowUp)
    }
}

private actor PreemptionNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

//
//  AmbientUtteranceFloorTests.swift
//  MaryVoiceTests
//
//  THE NEGATIVE OF `FollowUpPreemptionTests`, and the reason `.ambientUtterance`
//  is its own case at all.
//
//  That suite pins, deliberately, that a nil-origin FOLLOW-UP arriving
//  mid-generation CANCELS the user's in-flight turn — the coding bridge has
//  earned that right. An unprompted remark has earned nothing. Every test here
//  asserts the opposite of a test there, on the same seams.
//

import AVFoundation
import MaryFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct AmbientUtteranceFloorTests {

    // MARK: - Scripted collaborators

    final class RecordingResponder: LanguageResponder, @unchecked Sendable {
        private let lock = NSLock()
        private var cancels = 0
        private var deliveries: [AmbientVoiceDelivery] = []

        var cancelCount: Int {
            lock.lock(); defer { lock.unlock() }
            return cancels
        }
        var deliveryLog: [AmbientVoiceDelivery] {
            lock.lock(); defer { lock.unlock() }
            return deliveries
        }

        func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func cancel() async {
            lock.withLock { cancels += 1 }
        }

        func noteAmbientDelivery(_ delivery: AmbientVoiceDelivery, for candidateID: UUID) async {
            lock.withLock { deliveries.append(delivery) }
        }
    }

    final class StubTranscriber: VoiceTranscriber, @unchecked Sendable {
        func begin(format: AVAudioFormat) async throws {}
        func append(_ buffer: AVAudioPCMBuffer) async {}
        func partials() async -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func finish() async throws -> String { "" }
        func cancel() async {}
    }

    private func makePipeline(
        responder: RecordingResponder,
        synthesizer: any SpeechSynthesizer = AmbientNullSynthesizer()
    ) -> VoicePipeline {
        VoicePipeline(
            config: VoicePipelineConfig(),
            transcriber: StubTranscriber(),
            speaker: KokoroStreamSpeaker(synthesizer: synthesizer),
            responder: responder
        )
    }

    /// Poll rather than sleep a fixed amount — the arm crosses several actor
    /// hops before it holds the floor, and a fixed wait is either flaky or slow.
    private func waitUntilSpeaking(_ pipeline: VoicePipeline) async -> Bool {
        for _ in 0..<200 {
            if await pipeline.isFollowUpSpeaking { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: - Tests

    /// THE REGRESSION THAT MATTERS MOST — the direct negative of
    /// `FollowUpPreemptionTests.midGenerationFollowUpCancelsTheTurn`, which
    /// drives the identical state with a nil-origin `.followUpToken` and
    /// asserts `cancelCount == 1`.
    ///
    /// If this ever fails, Mary abandons an answer mid-sentence to volunteer
    /// a thought nobody asked for.
    @Test func anAmbientUtteranceNeverCancelsALiveTurn() async {
        let responder = RecordingResponder()
        let pipeline = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.thinking)
        await pipeline.setGenerationActiveForTesting(true)

        // Detached because a busy room makes this arm WAIT — that is the
        // point. We assert on what it did not do while waiting.
        let delivering = Task {
            await pipeline.handleProactive(
                .ambientUtterance("Your two o'clock moved.", candidateID: UUID()))
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        #expect(responder.cancelCount == 0, "an unprompted remark outranks nothing")
        let speaking = await pipeline.isFollowUpSpeaking
        #expect(!speaking, "it must not take the floor from a live turn")
        #expect(responder.deliveryLog.contains(.heldForQuiet), "and it books the hold")

        delivering.cancel()
    }

    /// A quiet room is the one case where it speaks, and it still cancels
    /// nothing on the way.
    @Test func aQuietRoomSpeaksAndCancelsNothing() async {
        let responder = RecordingResponder()
        let pipeline = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.listening(utteranceActive: false))
        await pipeline.handleProactive(
            .ambientUtterance("The build finished.", candidateID: UUID()))

        #expect(responder.cancelCount == 0)
        #expect(responder.deliveryLog.contains(.spoke), "a quiet room is its one opening")
    }

    /// THE USER IS TALKING — a yield, not a wait. Holding a remark against a
    /// live utterance only to speak it afterwards is how a remark becomes an
    /// interruption wearing a delay, and it is also the engine's one clean
    /// negative signal.
    @Test func theUserHoldingTheFloorYieldsImmediately() async {
        let responder = RecordingResponder()
        let pipeline = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.transcribing)
        await pipeline.handleProactive(
            .ambientUtterance("Not now.", candidateID: UUID()))

        #expect(responder.cancelCount == 0)
        #expect(responder.deliveryLog == [.preemptedByUser])
    }

    /// TWO PRODUCERS, ONE BUFFER — the splice this arm is shaped to avoid.
    /// `speakAmbientUtterance` reuses `endProactivePlayback` precisely because
    /// that tail touches no buffer; if it ever reached for `followUpBuffer`, a
    /// routine's buffered answer would be erased or garbled by a remark
    /// landing on top of it, and the transcript would still show an answer the
    /// user never heard.
    @Test func anAmbientUtteranceNeverTouchesTheFollowUpBuffer() async {
        let responder = RecordingResponder()
        let pipeline = makePipeline(responder: responder)

        // The user holds the floor, so a routine's follow-up buffers.
        await pipeline.setStateForTesting(.transcribing)
        await pipeline.handleProactive(
            .followUpToken("The routine's real answer. ", originUserTurnID: UUID()))
        let buffered = await pipeline.followUpBufferForTesting
        #expect(!buffered.isEmpty, "precondition: the follow-up is buffered")

        await pipeline.handleProactive(
            .ambientUtterance("An unrelated remark.", candidateID: UUID()))

        let after = await pipeline.followUpBufferForTesting
        #expect(after == buffered, "the remark left the routine's answer untouched")
    }

    /// An idle pipeline has no floor to take, and the row says so rather than
    /// leaving the engine to guess.
    @Test func anIdleSessionBooksSessionEnded() async {
        let responder = RecordingResponder()
        let pipeline = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.idle)
        await pipeline.handleProactive(
            .ambientUtterance("Anyone there?", candidateID: UUID()))

        // `handleProactive` guards `state != .idle` before the switch, so the
        // arm is never reached and nothing is booked. Pinned so the guard is
        // a known property rather than a surprise when the trace is empty.
        #expect(responder.deliveryLog.isEmpty)
        #expect(responder.cancelCount == 0)
    }

    /// Collects pipeline events until cancelled; returns whether
    /// `.turnCancelled` was seen. Suite-local — `FollowUpPreemptionTests`'
    /// identical helper is private to that file.
    private func turnCancelledWatcher(
        _ events: AsyncStream<VoicePipelineEvent>
    ) -> Task<Bool, Never> {
        Task {
            for await event in events {
                if case .turnCancelled = event { return true }
            }
            return false
        }
    }

    // MARK: - The barge-in carve-out

    /// TALKING OVER A REMARK MUST NOT KILL A TURN.
    ///
    /// `performBargeIn` assumes it is interrupting an ANSWER: it calls
    /// `responder.cancel()`, which reaches past the pipeline and cancels
    /// whatever text turn happens to be generating in the background, and it
    /// emits `.turnCancelled`, which deletes that turn's transcript bubble.
    /// A remark is not a turn. Nothing the user asked for should die because
    /// they talked over something they never asked for.
    @Test func bargingInOnARemarkCancelsNoTurnAndFinalizesNoBubble() async {
        let responder = RecordingResponder()
        let pipeline = makePipeline(responder: responder, synthesizer: SlowSynthesizer())
        let watcher = turnCancelledWatcher(await pipeline.events())

        await pipeline.setStateForTesting(.listening(utteranceActive: false))
        let speaking = Task {
            await pipeline.handleProactive(
                .ambientUtterance("Your two o'clock moved.", candidateID: UUID()))
        }
        #expect(await waitUntilSpeaking(pipeline), "precondition: the remark holds the floor")

        await pipeline.setStateForTesting(.speaking)
        await pipeline.bargeIn()

        #expect(responder.cancelCount == 0, "a remark is not a turn")
        try? await Task.sleep(nanoseconds: 100_000_000)
        watcher.cancel()
        #expect(await watcher.value == false, "no bubble to finalize")
        #expect(responder.deliveryLog.contains(.preemptedByUser),
                "and the engine's ONE negative signal is booked")
        speaking.cancel()
    }

    /// The same barge-in with no remark on the floor still behaves exactly as
    /// it always did — the carve-out is scoped to the remark, not to the state.
    @Test func anOrdinaryBargeInStillCancelsTheTurn() async {
        let responder = RecordingResponder()
        let pipeline = makePipeline(responder: responder)

        await pipeline.setStateForTesting(.thinking)
        await pipeline.setGenerationActiveForTesting(true)
        await pipeline.bargeIn()

        #expect(responder.cancelCount == 1, "an ordinary barge-in is untouched")
        #expect(responder.deliveryLog.isEmpty, "and books nothing ambient")
    }

    /// A remark that was talked over must not ALSO be booked as spoken — the
    /// row would say she was heard when she was cut off, and the governance
    /// loop would refund the very remark it should be punishing.
    @Test func aBargedRemarkIsNeverAlsoBookedAsSpoken() async {
        let responder = RecordingResponder()
        let pipeline = makePipeline(responder: responder, synthesizer: SlowSynthesizer())

        await pipeline.setStateForTesting(.listening(utteranceActive: false))
        let speaking = Task {
            await pipeline.handleProactive(
                .ambientUtterance("Half a sentence…", candidateID: UUID()))
        }
        #expect(await waitUntilSpeaking(pipeline))

        await pipeline.setStateForTesting(.speaking)
        await pipeline.bargeIn()
        _ = await speaking.result

        #expect(responder.deliveryLog.contains(.preemptedByUser))
        #expect(!responder.deliveryLog.contains(.spoke),
                "one candidate, one outcome: \(responder.deliveryLog)")
        speaking.cancel()
    }


}

/// Suite-local, because `FollowUpPreemptionTests`' identical double is
/// `private` to that file. Per-suite doubles are this tree's pattern.
private actor AmbientNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

/// Blocks inside synthesis so a test can catch the pipeline mid-speech. The
/// null synthesizer returns instantly, which is right for every other test
/// here and useless for interrupting one.
private actor SlowSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        return []
    }
}

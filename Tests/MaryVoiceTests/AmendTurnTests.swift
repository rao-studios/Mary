//
//  AmendTurnTests.swift
//  MaryVoiceTests
//
//  WHAT: The thinking-phase interrupt's SECOND half — what the correction
//        becomes, and which door it goes through.
//  OUT:  VoicePipeline.runTurn amend arm (join, supersede routing, re-arm)
//  PIN:  AmendPlannerTests covers WHEN to interrupt. This covers what the
//        interruption then SAYS: the original and the correction are one
//        utterance, and a turn the responder already saw must supersede
//        rather than arrive as a second question.
//  PIN:  A real session needs a mic; these drive internal test seams.
//

import AVFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct AmendTurnTests {

    // MARK: - Scripted collaborators

    /// Records the text AND the door — plain `respond` or `respondSuperseding`.
    final class AmendRecordingResponder: LanguageResponder, @unchecked Sendable {
        struct Call: Equatable {
            let text: String
            let superseding: Bool
        }
        private let lock = NSLock()
        private var recorded: [Call] = []
        var calls: [Call] { lock.withLock { recorded } }

        func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
            lock.withLock { recorded.append(Call(text: userText, superseding: false)) }
            return AsyncThrowingStream { $0.finish() }
        }
        func respondSuperseding(_ userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
            lock.withLock { recorded.append(Call(text: userText, superseding: true)) }
            return AsyncThrowingStream { $0.finish() }
        }
        func cancel() async {}
    }

    struct UnintelligibleAudio: Error {}

    /// `finish()` returns the scripted text, or throws when it is nil — the
    /// correction audio that defeated speech recognition.
    final class ScriptedTranscriber: VoiceTranscriber, @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        init(_ text: String?) { self.text = text }
        func begin(format: AVAudioFormat) async throws {}
        func append(_ buffer: AVAudioPCMBuffer) async {}
        func partials() async -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func finish() async throws -> String {
            guard let text = lock.withLock({ text }) else { throw UnintelligibleAudio() }
            return text
        }
        func cancel() async {}
    }

    final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [VoicePipelineEvent] = []
        func append(_ event: VoicePipelineEvent) { lock.withLock { collected.append(event) } }
        var events: [VoicePipelineEvent] { lock.withLock { collected } }

        var amendedTranscripts: [String] {
            events.compactMap {
                if case .amendedTranscript(let text) = $0 { return text }
                return nil
            }
        }
        var finalTranscripts: [String] {
            events.compactMap {
                if case .finalTranscript(let text) = $0 { return text }
                return nil
            }
        }
        var superseded: Int {
            events.reduce(into: 0) { count, event in
                if case .turnSuperseded = event { count += 1 }
            }
        }
    }

    private func makePipeline(
        correction: String?
    ) async -> (VoicePipeline, AmendRecordingResponder, EventBox, Task<Void, Never>) {
        let responder = AmendRecordingResponder()
        let pipeline = VoicePipeline(
            config: VoicePipelineConfig(),
            transcriber: ScriptedTranscriber(correction),
            speaker: KokoroStreamSpeaker(synthesizer: AmendNullSynthesizer()),
            responder: responder)
        let box = EventBox()
        let stream = await pipeline.events()
        let watcher = Task {
            for await event in stream {
                if Task.isCancelled { break }
                box.append(event)
            }
        }
        // Production claims the floor in `start()`; `submitTurn` needs a lease.
        await pipeline.setStateForTesting(.transcribing)
        return (pipeline, responder, box, watcher)
    }

    /// The pipeline hands off to the responder on its own task.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: - What the correction becomes

    /// THE WHOLE POINT OF THE FLOW. "Play the RAO playlist" — interrupted —
    /// "in Apple Music" is ONE request, and the model has to see both halves
    /// to answer it. The separator is deterministic: no second model pass
    /// stitches these together.
    @Test func theCorrectionJoinsTheOriginalAsOneUtterance() async {
        let (pipeline, responder, box, watcher) = await makePipeline(
            correction: "in Apple Music")
        await pipeline.armAmendForTesting(
            original: "play the RAO playlist", wasSubmitted: false)

        await pipeline.runTurnForTesting()
        await settle()

        #expect(box.amendedTranscripts == ["play the RAO playlist — in Apple Music"])
        #expect(responder.calls.map(\.text) == ["play the RAO playlist — in Apple Music"])
        #expect(box.finalTranscripts.isEmpty,
                "an amend is not a fresh transcript — the app already drew the original")
        watcher.cancel()
    }

    /// Correction audio that defeated speech recognition must not destroy the
    /// question the user already asked. `finish()` throwing is the real path.
    @Test func unintelligibleCorrectionKeepsTheOriginalQuery() async {
        let (pipeline, responder, box, watcher) = await makePipeline(correction: nil)
        await pipeline.armAmendForTesting(
            original: "what time is it", wasSubmitted: false)

        await pipeline.runTurnForTesting()
        await settle()

        #expect(box.amendedTranscripts == ["what time is it"])
        #expect(responder.calls.map(\.text) == ["what time is it"],
                "the original still gets answered — the correction is what was lost")
        watcher.cancel()
    }

    /// Whitespace-only correction is the same nothing.
    @Test func blankCorrectionKeepsTheOriginalQuery() async {
        let (pipeline, responder, _, watcher) = await makePipeline(correction: "   \n ")
        await pipeline.armAmendForTesting(
            original: "what time is it", wasSubmitted: false)

        await pipeline.runTurnForTesting()
        await settle()

        #expect(responder.calls.map(\.text) == ["what time is it"])
        watcher.cancel()
    }

    /// An interrupt that arrived before anything was transcribed leaves no
    /// original — the correction is simply the request.
    @Test func anEmptyOriginalSubmitsTheCorrectionAlone() async {
        let (pipeline, responder, _, watcher) = await makePipeline(
            correction: "open the build log")
        await pipeline.armAmendForTesting(original: "", wasSubmitted: false)

        await pipeline.runTurnForTesting()
        await settle()

        #expect(responder.calls.map(\.text) == ["open the build log"],
                "no leading separator when there is nothing to join to")
        watcher.cancel()
    }

    /// Both halves empty is not a turn. Nothing reaches the model and the mic re-arms.
    @Test func bothHalvesEmptyNeverReachesTheResponder() async {
        let (pipeline, responder, box, watcher) = await makePipeline(correction: "")
        await pipeline.armAmendForTesting(original: "", wasSubmitted: false)

        await pipeline.runTurnForTesting()
        await settle()

        #expect(responder.calls.isEmpty)
        #expect(box.amendedTranscripts.isEmpty)
        #expect(await pipeline.state == .listening(utteranceActive: false),
                "a turn that says nothing hands the mic back")
        watcher.cancel()
    }

    // MARK: - Which door the amended turn goes through

    /// THE REASON `wasSubmitted` EXISTS. The responder already opened an
    /// exchange for the original, so the amended question must REPLACE it.
    /// Arriving through plain `respond` would leave the abandoned question in
    /// history and answer the same request twice.
    @Test func anAmendThatReachedTheResponderSupersedes() async {
        let (pipeline, responder, _, watcher) = await makePipeline(
            correction: "in Apple Music")
        await pipeline.armAmendForTesting(
            original: "play the RAO playlist", wasSubmitted: true)

        await pipeline.runTurnForTesting()
        await settle()

        #expect(responder.calls == [
            .init(text: "play the RAO playlist — in Apple Music", superseding: true),
        ])
        watcher.cancel()
    }

    /// Interrupted before the responder ever saw it: there is no exchange to
    /// replace, so history surgery would be a lie.
    @Test func anAmendThatNeverReachedTheResponderDoesNotSupersede() async {
        let (pipeline, responder, _, watcher) = await makePipeline(
            correction: "in Apple Music")
        await pipeline.armAmendForTesting(
            original: "play the RAO playlist", wasSubmitted: false)

        await pipeline.runTurnForTesting()
        await settle()

        #expect(responder.calls == [
            .init(text: "play the RAO playlist — in Apple Music", superseding: false),
        ])
        watcher.cancel()
    }

    /// The unintelligible-correction path keeps the supersede decision too —
    /// the original was submitted, so re-answering it must replace, not repeat.
    @Test func unintelligibleCorrectionStillSupersedesWhenTheOriginalWasSubmitted() async {
        let (pipeline, responder, _, watcher) = await makePipeline(correction: nil)
        await pipeline.armAmendForTesting(
            original: "what time is it", wasSubmitted: true)

        await pipeline.runTurnForTesting()
        await settle()

        #expect(responder.calls == [.init(text: "what time is it", superseding: true)])
        watcher.cancel()
    }

    // MARK: - The flow ends

    /// One amend, one turn. A stale context would silently glue the NEXT
    /// utterance onto this one.
    @Test func theAmendContextIsClearedSoTheNextTurnStandsAlone() async {
        let (pipeline, responder, box, watcher) = await makePipeline(correction: "in Apple Music")
        await pipeline.armAmendForTesting(
            original: "play the RAO playlist", wasSubmitted: false)

        await pipeline.runTurnForTesting()
        await settle()
        #expect(await pipeline.amendContextForTesting == nil)

        // A second turn on the same pipeline takes the ordinary path.
        await pipeline.setStateForTesting(.transcribing)
        await pipeline.runTurnForTesting()
        await settle()

        #expect(box.finalTranscripts == ["in Apple Music"],
                "the next utterance is its own transcript, not a continuation")
        #expect(responder.calls.map(\.text) == [
            "play the RAO playlist — in Apple Music",
            "in Apple Music",
        ])
        watcher.cancel()
    }

    /// A commit that landed while the ORIGINAL was still transcribing: the
    /// text that finally resolves is the original, and the correction is still
    /// in the side buffer — so this turn must divert into the amend flow
    /// rather than submit. (Headless the capture cannot open a mic, so the
    /// assertion is that nothing was submitted, not what was buffered.)
    @Test func aCommitDuringTranscriptionDivertsInsteadOfSubmitting() async {
        let (pipeline, responder, box, watcher) = await makePipeline(
            correction: "play the RAO playlist")
        await pipeline.setPendingAmendCommitForTesting()

        await pipeline.runTurnForTesting()
        await settle()

        #expect(responder.calls.isEmpty,
                "the resolved transcript becomes the amend original, not a question")
        #expect(box.superseded == 1, "the turn hands over to the correction")
        #expect(box.finalTranscripts.isEmpty)
        watcher.cancel()
    }
}

private actor AmendNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

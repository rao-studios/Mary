//
//  WakeSessionTests.swift
//  MaryVoiceTests
//
//  WHAT: Wake-word seams — primeTurn, greeting, stop-listening ack-before-end.
//  OUT:  VoicePipeline wake session
//  PIN:  A real session needs a mic; these drive internal test seams
//

import AVFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct WakeSessionTests {

    // MARK: - Scripted collaborators

    final class QueryRecordingResponder: LanguageResponder, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var queries: [String] { lock.withLock { recorded } }

        func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
            lock.withLock { recorded.append(userText) }
            return AsyncThrowingStream { $0.finish() }
        }
        func cancel() async {}
    }

    final class ScriptedFinishTranscriber: VoiceTranscriber, @unchecked Sendable {
        private let lock = NSLock()
        private var finishText: String
        init(finishText: String = "") { self.finishText = finishText }
        func begin(format: AVAudioFormat) async throws {}
        func append(_ buffer: AVAudioPCMBuffer) async {}
        func partials() async -> AsyncStream<String> { AsyncStream { $0.finish() } }
        func finish() async throws -> String { lock.withLock { finishText } }
        func cancel() async {}
    }

    /// Collects every event until cancelled.
    final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [VoicePipelineEvent] = []
        var events: [VoicePipelineEvent] { lock.withLock { collected } }
        func append(_ event: VoicePipelineEvent) { lock.withLock { collected.append(event) } }

        var finalTranscripts: [String] {
            events.compactMap {
                if case .finalTranscript(let text) = $0 { return text }
                return nil
            }
        }
        var stopCommands: [(transcript: String, ack: String)] {
            events.compactMap {
                if case .stopListeningCommand(let transcript, let ack) = $0 {
                    return (transcript, ack)
                }
                return nil
            }
        }
    }

    /// Ordered cross-collaborator log: synth calls and event arrivals land in
    /// one sequence so BEFORE/AFTER is assertable.
    final class OrderedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var entries: [String] { lock.withLock { recorded } }
        func append(_ entry: String) { lock.withLock { recorded.append(entry) } }
    }

    final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var arrivals = 0
        var arrivalCount: Int { lock.withLock { arrivals } }

        func park() async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    arrivals += 1
                    waiter = continuation
                }
            }
        }

        func release() {
            let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let held = waiter
                waiter = nil
                return held
            }
            held?.resume()
        }
    }

    final class SuspendedContinuous: ContinuousTranscribing, @unchecked Sendable {
        let appendGate = OneShotGate()
        func segments() async -> AsyncStream<TranscriptSegment> {
            AsyncStream { $0.finish() }
        }
        func beginSession(format: AVAudioFormat) async throws {}
        func appendContinuous(_ buffer: AVAudioPCMBuffer) async {
            await appendGate.park()
        }
        func endSession() async { appendGate.release() }
    }

    final class SpeakerPauseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var paused = false
        var sawPause: Bool { lock.withLock { paused } }
        func record(_ event: SpeakerEvent) {
            guard case .paused = event else { return }
            lock.withLock { paused = true }
        }
    }

    private func waitUntil(
        _ timeout: TimeInterval = 2,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func frame(rms: Float = 0.1) -> MicFrame {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        return MicFrame(buffer: buffer, rms: rms, duration: 0.1)
    }

    private func makePipeline(
        transcriber: ScriptedFinishTranscriber = ScriptedFinishTranscriber(),
        stopListeningAck: String? = nil,
        orderedLog: OrderedLog? = nil,
        synthesizer overrideSynthesizer: (any SpeechSynthesizer)? = nil
    ) async -> (
        VoicePipeline, QueryRecordingResponder, EventBox, Task<Void, Never>,
        KokoroStreamSpeaker
    ) {
        let responder = QueryRecordingResponder()
        let synthesizer: any SpeechSynthesizer = overrideSynthesizer
            ?? orderedLog.map { WakeRecordingSynthesizer(log: $0) }
            ?? WakeNullSynthesizer()
        let speaker = KokoroStreamSpeaker(synthesizer: synthesizer)
        // ALWAYS the deterministic transport, never a real AVAudioEngine.
        // Without a driver, `playWithRing` attaches and starts a live engine
        // per pipeline; a wedged CoreAudio HAL (measured: serial full run 4,
        // after ~3,000 tests of engine churn) parks the drain await inside
        // `speaker.flush` forever — `performStopListening` deliberately has
        // no guillotine on the ack drain, so the parked flush parked
        // `primedStopListeningIsIntercepted`, and with it the entire test
        // process, at 0% CPU.
        await speaker.setDataPlayedBackDriverForTesting { samples, _, text in
            guard let orderedLog else { return }
            #expect(!samples.isEmpty, "the acknowledgement carries real PCM")
            orderedLog.append("playback-started:\(text)")
            try? await Task.sleep(nanoseconds: 20_000_000)
            // Returning from this closure is the deterministic test
            // transport's `.dataPlayedBack` callback.
            orderedLog.append("data-played-back:\(text)")
        }
        let pipeline = VoicePipeline(
            config: VoicePipelineConfig(stopListeningAck: stopListeningAck),
            transcriber: transcriber,
            speaker: speaker,
            responder: responder)
        let box = EventBox()
        let stream = await pipeline.events()
        let watcher = Task {
            for await event in stream {
                if Task.isCancelled { break }
                if case .stopListeningCommand = event {
                    if let orderedLog {
                        let stillSpeaking = await speaker.isSpeaking
                        orderedLog.append(stillSpeaking ? "event-during-playback" : "event-after-drain")
                    }
                    orderedLog?.append("event")
                }
                box.append(event)
            }
        }
        return (pipeline, responder, box, watcher, speaker)
    }

    // MARK: - primeTurn

    @Test func primedTurnRunsAsANormalFirstTurn() async {
        let (pipeline, responder, box, watcher, _) = await makePipeline()
        await pipeline.setStateForTesting(.listening(utteranceActive: false))

        let accepted = await pipeline.primeTurn(query: "what time is it")

        #expect(accepted)
        #expect(responder.queries == ["what time is it"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(box.finalTranscripts == ["what time is it"],
                "the app mirrors the user bubble exactly as for a spoken turn")
        watcher.cancel()
    }

    @Test func primedTurnYieldsToALiveUtterance() async {
        let (pipeline, responder, _, watcher, _) = await makePipeline()
        await pipeline.setStateForTesting(.listening(utteranceActive: true))

        let accepted = await pipeline.primeTurn(query: "what time is it")

        #expect(!accepted, "the user's live utterance outranks the primed one")
        #expect(responder.queries.isEmpty)
        watcher.cancel()
    }

    // MARK: - speakCannedLine

    @Test func cannedLineSpeaksIntoAQuietRoom() async {
        let (pipeline, _, _, watcher, _) = await makePipeline()
        await pipeline.setStateForTesting(.listening(utteranceActive: false))

        #expect(await pipeline.speakCannedLine("Yes?"))
        watcher.cancel()
    }

    @Test func cannedLineDropsWhileBusy() async {
        let (pipeline, _, _, watcher, _) = await makePipeline()
        await pipeline.setStateForTesting(.thinking)

        #expect(await !pipeline.speakCannedLine("Yes?"),
                "a greeting outranks nothing — a busy room drops it")
        watcher.cancel()
    }

    // MARK: - "stop listening"

    @Test func stopListeningNeverReachesTheResponder() async {
        let transcriber = ScriptedFinishTranscriber(finishText: "mary stop listening")
        let (pipeline, responder, box, watcher, _) = await makePipeline(
            transcriber: transcriber,
            stopListeningAck: "Okay — say “Hey Mary” when you need me.")
        await pipeline.setStateForTesting(.transcribing)

        await pipeline.runTurnForTesting()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(responder.queries.isEmpty, "no model ever sees the command")
        #expect(box.finalTranscripts.isEmpty, "a command is not a turn — no user bubble event")
        #expect(box.stopCommands.count == 1)
        #expect(box.stopCommands.first?.transcript == "mary stop listening")
        #expect(box.stopCommands.first?.ack == "Okay — say “Hey Mary” when you need me.")
        watcher.cancel()
    }

    /// "Hey Mary, stop listening" arrives as a primed remainder — the
    /// command must end the session through that door too, not become a
    /// model query.
    @Test func primedStopListeningIsIntercepted() async {
        let (pipeline, responder, box, watcher, _) = await makePipeline(
            stopListeningAck: "Okay.")
        await pipeline.setStateForTesting(.listening(utteranceActive: false))

        let accepted = await pipeline.primeTurn(query: "stop listening")
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(accepted)
        #expect(responder.queries.isEmpty, "no model ever sees the command")
        #expect(box.finalTranscripts.isEmpty,
                "no user-bubble event — the stop arm mirrors the exchange itself")
        #expect(box.stopCommands.count == 1)
        watcher.cancel()
    }

    /// Invariant: the ack has fully synthesized and drained BEFORE the event
    /// that ends the session — so nothing the app re-arms can overhear the
    /// ack's own "Hey Mary".
    @Test func ackSynthesizesBeforeTheStopEventIsEmitted() async {
        let log = OrderedLog()
        let transcriber = ScriptedFinishTranscriber(finishText: "stop listening")
        let acknowledgement = "Okay — say “Hey Mary” when you need me."
        let (pipeline, _, box, watcher, _) = await makePipeline(
            transcriber: transcriber,
            stopListeningAck: acknowledgement,
            orderedLog: log)
        await pipeline.setStateForTesting(.transcribing)

        await pipeline.runTurnForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(box.stopCommands.count == 1)
        let entries = log.entries
        let synthIndex = entries.firstIndex(of: "synth:\(acknowledgement)")
        let playedIndex = entries.firstIndex(of: "data-played-back:\(acknowledgement)")
        let drainedIndex = entries.firstIndex(of: "event-after-drain")
        let eventIndex = entries.firstIndex(of: "event")
        #expect(synthIndex != nil, "the ack reached the synthesizer")
        #expect(playedIndex != nil, "non-empty acknowledgement PCM reached dataPlayedBack")
        #expect(drainedIndex != nil, "the speaker was idle before the stop event")
        #expect(eventIndex != nil)
        if let synthIndex, let playedIndex, let drainedIndex, let eventIndex {
            #expect(synthIndex < playedIndex)
            #expect(playedIndex < drainedIndex,
                    "dataPlayedBack strictly precedes the session-ending event")
            #expect(drainedIndex < eventIndex)
        }
        watcher.cancel()
    }

    /// A frame already dispatched by the mic loop may be suspended in the
    /// continuous analyzer when the stop command changes the state to
    /// `.speaking`. It must not resume into the barge-in branch and pause the
    /// acknowledgement with no later frame available to resume it.
    @Test func aSuspendedCommandTailFrameCannotPauseTheGoodbye() async {
        let log = OrderedLog()
        let playbackGate = OneShotGate()
        let continuous = SuspendedContinuous()
        let transcriber = ScriptedFinishTranscriber(finishText: "stop listening")
        let responder = QueryRecordingResponder()
        let speaker = KokoroStreamSpeaker(
            synthesizer: WakeRecordingSynthesizer(log: log))
        await speaker.setDataPlayedBackDriverForTesting { samples, _, text in
            #expect(!samples.isEmpty)
            log.append("playback-started:\(text)")
            await playbackGate.park()
            log.append("data-played-back:\(text)")
        }
        let pipeline = VoicePipeline(
            config: VoicePipelineConfig(
                stopListeningAck: "Okay — say “Hey Mary” when you need me."),
            transcriber: transcriber,
            speaker: speaker,
            responder: responder,
            continuous: continuous)

        let pauseBox = SpeakerPauseBox()
        let speakerEvents = await speaker.events()
        let speakerWatcher = Task {
            for await event in speakerEvents {
                if Task.isCancelled { break }
                pauseBox.record(event)
            }
        }

        await pipeline.setStateForTesting(.listening(utteranceActive: false))
        let staleFrame = Task {
            await pipeline.handleFrameForTesting(frame())
        }
        #expect(await waitUntil { continuous.appendGate.arrivalCount == 1 })

        await pipeline.setStateForTesting(.transcribing)
        let goodbye = Task { await pipeline.runTurnForTesting() }
        #expect(await waitUntil { playbackGate.arrivalCount == 1 })

        continuous.appendGate.release()
        await staleFrame.value
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(!pauseBox.sawPause,
                "the stale mic frame must be rejected before barge-in")

        playbackGate.release()
        await goodbye.value
        #expect(log.entries.contains { $0.hasPrefix("data-played-back:") })

        await pipeline.stop()
        speakerWatcher.cancel()
    }

    /// An explicit external stop may race an acknowledgement suspended in
    /// Sewn/fallback. It must cancel that work and invalidate the old exit so
    /// the continuation cannot later emit a duplicate command.
    @Test func anExternalStopCancelsAnInFlightGoodbyeIdempotently() async {
        let transcriber = ScriptedFinishTranscriber(finishText: "stop listening")
        let (pipeline, responder, box, watcher, _) = await makePipeline(
            transcriber: transcriber,
            stopListeningAck: "Okay.",
            synthesizer: WakeHangingSynthesizer())
        await pipeline.setStateForTesting(.transcribing)

        let goodbye = Task { await pipeline.runTurnForTesting() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await pipeline.stop()
        await goodbye.value

        #expect(box.stopCommands.isEmpty,
                "the external stop won; the stale goodbye emits no second stop")
        #expect(await pipeline.state == .idle)
        #expect(responder.queries.isEmpty)
        watcher.cancel()
    }

    /// Sewn owns its normal request timeout. The pipeline adds no shorter
    /// first-audio guillotine, and playback still drains before session exit.
    @Test func aSlowButLivingGoodbyeIsNotCutOff() async {
        let log = OrderedLog()
        let transcriber = ScriptedFinishTranscriber(finishText: "stop listening")
        let (pipeline, _, box, watcher, _) = await makePipeline(
            transcriber: transcriber,
            stopListeningAck: "Okay, going quiet.",
            // Deliberately beyond the removed six-second pipeline cutoff.
            // Sewn still owns its transport bounds; a living request is not
            // killed by a second, shorter acknowledgement timer.
            synthesizer: WakeSlowSynthesizer(log: log, delay: 6.25))
        await pipeline.setStateForTesting(.transcribing)

        let began = Date()
        await pipeline.runTurnForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(box.stopCommands.count == 1)
        #expect(Date().timeIntervalSince(began) >= 6.2,
                "the pipeline waited for the living primary backend")
        let entries = log.entries
        #expect(entries.contains { $0.hasPrefix("synth:") },
                "the slow line still reached the synthesizer")
        if let synthIndex = entries.firstIndex(where: { $0.hasPrefix("synth:") }),
           let eventIndex = entries.firstIndex(of: "event") {
            #expect(synthIndex < eventIndex,
                    "and it finished before the session-ending event")
        }
        watcher.cancel()
    }

    @Test func nilAckDisablesTheIntercept() async {
        let transcriber = ScriptedFinishTranscriber(finishText: "stop listening")
        let (pipeline, responder, box, watcher, _) = await makePipeline(
            transcriber: transcriber, stopListeningAck: nil)
        await pipeline.setStateForTesting(.transcribing)

        await pipeline.runTurnForTesting()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(responder.queries == ["stop listening"],
                "probes and tests keep the words as an ordinary turn")
        #expect(box.stopCommands.isEmpty)
        watcher.cancel()
    }

    @Test func anOrdinaryTurnStillSubmitsWithTheAckConfigured() async {
        let transcriber = ScriptedFinishTranscriber(finishText: "what's on my calendar")
        let (pipeline, responder, box, watcher, _) = await makePipeline(
            transcriber: transcriber, stopListeningAck: "Okay.")
        await pipeline.setStateForTesting(.transcribing)

        await pipeline.runTurnForTesting()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(responder.queries == ["what's on my calendar"])
        #expect(box.finalTranscripts == ["what's on my calendar"])
        #expect(box.stopCommands.isEmpty)
        watcher.cancel()
    }
}

private actor WakeNullSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] { [] }
}

/// A backend that IS working, just not instantly — a cloud round trip, or a
/// cold on-device model load.
private actor WakeSlowSynthesizer: SpeechSynthesizer {
    private let log: WakeSessionTests.OrderedLog
    private let delay: TimeInterval
    init(log: WakeSessionTests.OrderedLog, delay: TimeInterval) {
        self.log = log
        self.delay = delay
    }
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        log.append("synth:\(text)")
        return [Float](repeating: 0.02, count: 2_400)
    }
}

/// Simulates the live failure: synthesis that never returns.
private actor WakeHangingSynthesizer: SpeechSynthesizer {
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] {
        try await Task.sleep(nanoseconds: 600_000_000_000)
        return [Float](repeating: 0.02, count: 2_400)
    }
}

private actor WakeRecordingSynthesizer: SpeechSynthesizer {
    private let log: WakeSessionTests.OrderedLog
    init(log: WakeSessionTests.OrderedLog) { self.log = log }
    var sampleRate: Double { 24_000 }
    var lastPronunciationReport: PronunciationReport? { nil }
    func synthesizeWaveform(_ text: String) async throws -> [Float] {
        log.append("synth:\(text)")
        return [Float](repeating: 0.02, count: 2_400)
    }
}

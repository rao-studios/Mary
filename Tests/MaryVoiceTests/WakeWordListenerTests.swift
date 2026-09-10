//
//  WakeWordListenerTests.swift
//  MaryVoiceTests
//
//  WHAT: Standby ear — wake emits, everything else is silent, self-speech never opens.
//  OUT:  WakeWordListener via injected frame source
//

import AVFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct WakeWordListenerTests {

    // MARK: - Scripted collaborators

    final class ScriptedWakeTranscriber: VoiceTranscriber, @unchecked Sendable {
        private let lock = NSLock()
        private var finishText: String
        private var beginError: Error?
        private var begins = 0
        private var cancels = 0
        private var finishes = 0
        private var partialContinuation: AsyncStream<String>.Continuation?

        init(finishText: String, beginError: Error? = nil) {
            self.finishText = finishText
            self.beginError = beginError
        }

        var beginCount: Int { lock.withLock { begins } }
        var cancelCount: Int { lock.withLock { cancels } }
        var finishCount: Int { lock.withLock { finishes } }

        func setFinishText(_ text: String) { lock.withLock { finishText = text } }

        func begin(format: AVAudioFormat) async throws {
            let error: Error? = lock.withLock {
                begins += 1
                return beginError
            }
            if let error { throw error }
        }

        func append(_ buffer: AVAudioPCMBuffer) async {}

        func partials() async -> AsyncStream<String> {
            let (stream, continuation) = AsyncStream<String>.makeStream()
            lock.withLock { partialContinuation = continuation }
            return stream
        }

        func finish() async throws -> String {
            lock.withLock {
                finishes += 1
                return finishText
            }
        }

        func cancel() async {
            let continuation: AsyncStream<String>.Continuation? = lock.withLock {
                cancels += 1
                let held = partialContinuation
                partialContinuation = nil
                return held
            }
            continuation?.finish()
        }

        func pushPartial(_ text: String) {
            let continuation = lock.withLock { partialContinuation }
            continuation?.yield(text)
        }
    }

    /// A cancellation-insensitive begin seam: it models Speech/URL work that
    /// resumes normally after the listener has already stopped.
    final class SuspendedBeginTranscriber: VoiceTranscriber, @unchecked Sendable {
        private let lock = NSLock()
        private var beginContinuation: CheckedContinuation<Void, Never>?
        private var begins = 0
        private var appends = 0
        private var partialSubscriptions = 0
        private var cancels = 0

        var beginCount: Int { lock.withLock { begins } }
        var appendCount: Int { lock.withLock { appends } }
        var partialCount: Int { lock.withLock { partialSubscriptions } }
        var cancelCount: Int { lock.withLock { cancels } }

        func begin(format: AVAudioFormat) async throws {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    begins += 1
                    beginContinuation = continuation
                }
            }
        }

        func resumeBegin() {
            let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let held = beginContinuation
                beginContinuation = nil
                return held
            }
            held?.resume()
        }

        func append(_ buffer: AVAudioPCMBuffer) async {
            lock.withLock { appends += 1 }
        }

        func partials() async -> AsyncStream<String> {
            lock.withLock { partialSubscriptions += 1 }
            return AsyncStream { $0.finish() }
        }

        func finish() async throws -> String { "hey mary" }
        func cancel() async { lock.withLock { cancels += 1 } }
    }

    // MARK: - Harness

    private func frame(rms: Float, duration: TimeInterval = 0.1) -> MicFrame {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        return MicFrame(buffer: buffer, rms: rms, duration: duration)
    }

    /// One complete utterance at the default VAD tuning: enough voiced time
    /// to clear `minUtteranceMs`, enough silence to clear `hangoverMs`.
    private func speakUtterance(into continuation: AsyncStream<MicFrame>.Continuation) {
        for _ in 0..<6 { continuation.yield(frame(rms: 0.05)) }
        for _ in 0..<10 { continuation.yield(frame(rms: 0.001)) }
    }

    private func makeListener(
        transcriber: ScriptedWakeTranscriber,
        selfSpeech: (@Sendable () async -> Bool)? = nil,
        maxUtteranceSeconds: TimeInterval = 12
    ) -> (WakeWordListener, AsyncStream<MicFrame>.Continuation) {
        let (frames, continuation) = AsyncStream<MicFrame>.makeStream()
        let listener = WakeWordListener(
            config: WakeListenerConfig(maxUtteranceSeconds: maxUtteranceSeconds),
            transcriber: transcriber,
            selfSpeech: selfSpeech,
            frameSource: frames)
        return (listener, continuation)
    }

    private func firstEvent(
        _ stream: AsyncStream<WakeEvent>, within timeout: TimeInterval = 3
    ) async -> WakeEvent? {
        await withTaskGroup(of: WakeEvent?.self) { group in
            group.addTask {
                for await event in stream { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func waitUntil(
        _ timeout: TimeInterval = 2, condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    // MARK: - Tests

    @Test func bareWakeEmits() async throws {
        let transcriber = ScriptedWakeTranscriber(finishText: "hey mary")
        let (listener, frames) = makeListener(transcriber: transcriber)
        let events = await listener.events()
        try await listener.start()

        speakUtterance(into: frames)
        #expect(await firstEvent(events) == .wake(remainder: nil))
        await listener.stop()
    }

    @Test func wakeWithRequestForwardsTheRemainder() async throws {
        let transcriber = ScriptedWakeTranscriber(finishText: "Hey Mary, turn on the lights")
        let (listener, frames) = makeListener(transcriber: transcriber)
        let events = await listener.events()
        try await listener.start()

        speakUtterance(into: frames)
        #expect(await firstEvent(events) == .wake(remainder: "turn on the lights"))
        await listener.stop()
    }

    /// A non-wake utterance emits NOTHING — pinned by making a wake follow
    /// it: the first event to arrive must be the second utterance's.
    @Test func roomTalkIsDiscarded() async throws {
        let transcriber = ScriptedWakeTranscriber(finishText: "we should ship on friday")
        let (listener, frames) = makeListener(transcriber: transcriber)
        let events = await listener.events()
        try await listener.start()

        speakUtterance(into: frames)
        let discarded = await waitUntil { transcriber.finishCount == 1 }
        #expect(discarded, "the first utterance resolved")

        transcriber.setFinishText("mary")
        speakUtterance(into: frames)
        #expect(await firstEvent(events) == .wake(remainder: nil),
                "the wake is the FIRST event — room talk emitted nothing")
        await listener.stop()
    }

    @Test func earlyAbortCancelsTranscription() async throws {
        let transcriber = ScriptedWakeTranscriber(finishText: "never reached")
        let (listener, frames) = makeListener(transcriber: transcriber)
        _ = await listener.events()
        try await listener.start()

        // Open the utterance and hold it voiced while the partial arrives.
        for _ in 0..<4 { frames.yield(frame(rms: 0.05)) }
        let opened = await waitUntil { transcriber.beginCount == 1 }
        #expect(opened, "the utterance opened a transcriber session")
        // Subscription races the first partial; settle briefly, then push.
        try? await Task.sleep(nanoseconds: 100_000_000)
        transcriber.pushPartial("so I was saying")

        let aborted = await waitUntil { transcriber.cancelCount >= 1 }
        #expect(aborted, "a ruled-out partial cancels transcription mid-utterance")

        // The utterance closes without ever calling finish().
        for _ in 0..<10 { frames.yield(frame(rms: 0.001)) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(transcriber.finishCount == 0)
        await listener.stop()
    }

    @Test func selfSpeechNeverOpensAnUtterance() async throws {
        let transcriber = ScriptedWakeTranscriber(finishText: "mary")
        let (listener, frames) = makeListener(
            transcriber: transcriber, selfSpeech: { true })
        _ = await listener.events()
        try await listener.start()

        speakUtterance(into: frames)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(transcriber.beginCount == 0,
                "her own TTS must not open wake utterances")
        await listener.stop()
    }

    @Test func stoppedListenerCannotResurrectAfterBeginResumes() async throws {
        let transcriber = SuspendedBeginTranscriber()
        let (frames, continuation) = AsyncStream<MicFrame>.makeStream()
        let listener = WakeWordListener(
            transcriber: transcriber,
            frameSource: frames)
        _ = await listener.events()
        try await listener.start()

        for _ in 0..<6 { continuation.yield(frame(rms: 0.05)) }
        let began = await waitUntil { transcriber.beginCount == 1 }
        #expect(began)

        await listener.stop()
        transcriber.resumeBegin()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(transcriber.partialCount == 0,
                "a stale begin may not spawn a new partial-consumer task")
        #expect(transcriber.appendCount == 0,
                "a stale begin may not resume feeding audio")
        #expect(transcriber.cancelCount >= 1)
    }

    @Test func theCapForceClosesAndStillMatches() async throws {
        let transcriber = ScriptedWakeTranscriber(finishText: "hey mary book me a table")
        let (listener, frames) = makeListener(transcriber: transcriber, maxUtteranceSeconds: 1)
        let events = await listener.events()
        try await listener.start()

        // Voiced past the 1 s cap with no silence — VAD never closes it.
        for _ in 0..<15 { frames.yield(frame(rms: 0.05)) }
        #expect(await firstEvent(events) == .wake(remainder: "book me a table"),
                "the cap closes the utterance and the wake prefix is honored")
        await listener.stop()
    }

    @Test func deadPermissionDeclaresUnavailableOnce() async throws {
        let transcriber = ScriptedWakeTranscriber(
            finishText: "", beginError: TranscriberError.notAuthorized)
        let (listener, frames) = makeListener(transcriber: transcriber)
        let events = await listener.events()
        try await listener.start()

        speakUtterance(into: frames)
        let event = await firstEvent(events)
        guard case .unavailable = event else {
            Issue.record("expected .unavailable, got \(String(describing: event))")
            return
        }
        // The listener stopped itself — the stream is finished, so a second
        // utterance can produce nothing at all.
        speakUtterance(into: frames)
        #expect(await firstEvent(events, within: 0.5) == nil)
    }
}

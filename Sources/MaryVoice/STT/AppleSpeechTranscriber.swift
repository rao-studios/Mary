//
//  AppleSpeechTranscriber.swift
//  MaryVoice
//
//  Live on-device STT via SFSpeechAudioBufferRecognitionRequest — partial
//  results as you speak, final on endpoint. Pattern informed by FleetAudio's
//  file-based SpeechTranscriber (on-device forced, authorization first).
//

import AVFoundation
import Foundation
import Speech

public actor AppleSpeechTranscriber: VoiceTranscriber {

    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var lastPartial: String = ""
    private var finalText: String?
    private var finished = false
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var finishWaiter: CheckedContinuation<String, Error>?

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    // MARK: - VoiceTranscriber

    public func begin(format: AVAudioFormat) async throws {
        guard await Self.requestAuthorization() == .authorized else {
            throw TranscriberError.notAuthorized
        }
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        self.recognizer = recognizer

        cleanupUtterance()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        lastPartial = ""
        finalText = nil
        finished = false

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { await self.handle(result: result, error: error) }
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    public func partials() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4))
        partialContinuation = continuation
        return stream
    }

    /// End audio and wait briefly for the recognizer's final result; the last
    /// partial is a perfectly good transcript if the final never lands.
    public func finish() async throws -> String {
        request?.endAudio()

        if let finalText {
            cleanupUtterance()
            return finalText
        }

        let text = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            var resumed = false
            let resumeOnce: (String) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                c.resume(returning: value)
            }
            self.finishResume = resumeOnce
            // ~2 s grace for the final result, then fall back to the partial.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.timeoutFinish()
            }
        }
        cleanupUtterance()
        guard !text.isEmpty else { throw TranscriberError.noSpeech }
        return text
    }

    public func cancel() {
        cleanupUtterance()
    }

    // MARK: - Internals

    private var finishResume: ((String) -> Void)?

    private func timeoutFinish() {
        finishResume?(finalText ?? lastPartial)
        finishResume = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                finalText = text
                finishResume?(text)
                finishResume = nil
            } else {
                lastPartial = text
                partialContinuation?.yield(text)
            }
        }
        if error != nil {
            // Recognition errors after endAudio are routine (e.g. "no speech");
            // resolve with whatever we heard.
            finishResume?(finalText ?? lastPartial)
            finishResume = nil
        }
    }

    private func cleanupUtterance() {
        task?.cancel()
        task = nil
        request = nil
        partialContinuation?.finish()
        partialContinuation = nil
        finishResume = nil
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

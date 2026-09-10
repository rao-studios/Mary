//
//  AppleSpeechTranscriber.swift
//  MaryVoice
//
//  WHAT: Live on-device STT via SFSpeechAudioBufferRecognitionRequest.
//  IN:   VoicePipeline / WakeWordListener (VoiceTranscriber)
//  OUT:  partials stream + finish() transcript
//  PIN:  Results apply in arrival order, through one stream. A final that lands
//        before endAudio commits its segment and the next buffer opens a fresh
//        task — it is never the answer to finish().
//

import AVFoundation
import Foundation
import Speech
import os

public actor AppleSpeechTranscriber: VoiceTranscriber {

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "voice.stt")
    /// Grace for the closing final after endAudio; past it the assembled transcript stands.
    private static let finalGrace: Duration = .seconds(2)
    /// Early-closed tasks reopened per utterance before the rest is dropped.
    private static let maxReopens = 4

    /// One recognition callback, tagged with the task that produced it.
    private struct Update: Sendable {
        let task: UInt64
        let text: String?
        let isFinal: Bool
        let failed: Bool
    }

    private let locale: Locale
    /// Words the recognizer should prefer — her name, project names.
    private let contextualStrings: [String]

    /// Kept across utterances so `begin` does no cold work on the speech-start frame.
    private var recognizer: SFSpeechRecognizer?
    private var authorized = false

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Current task's tag. Updates from a replaced task are ignored.
    private var taskSeq: UInt64 = 0
    /// The task closed before endAudio; the next buffer opens a new one.
    private var taskClosed = false
    private var reopens = 0

    private var updates: AsyncStream<Update>.Continuation?
    private var updatesTask: Task<Void, Never>?

    private var assembler = TranscriptAssembler()
    private var audioEnded = false
    private var utteranceID: UInt64 = 0
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var finishResume: ((String) -> Void)?

    public init(locale: Locale = .current, contextualStrings: [String] = []) {
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    // MARK: - VoiceTranscriber

    public func prewarm(format: AVAudioFormat) async {
        _ = try? await readyRecognizer()
    }

    public func begin(format: AVAudioFormat) async throws {
        _ = try await readyRecognizer()
        cleanupUtterance()

        utteranceID &+= 1
        assembler = TranscriptAssembler()
        audioEnded = false
        reopens = 0

        let (stream, continuation) = AsyncStream<Update>.makeStream()
        updates = continuation
        // One consumer, so results apply in the order the recognizer sent them.
        updatesTask = Task { [weak self] in
            for await update in stream {
                await self?.apply(update)
            }
        }
        startTask()
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        if taskClosed, !audioEnded, reopens < Self.maxReopens {
            reopens += 1
            Self.log.notice("recognizer closed mid-utterance; reopening (\(self.reopens))")
            startTask()
        }
        request?.append(buffer)
    }

    public func partials() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4))
        partialContinuation = continuation
        return stream
    }

    /// End audio and wait briefly for the closing final; the assembled transcript is the fallback.
    public func finish() async throws -> String {
        audioEnded = true
        let text: String
        if taskClosed || task == nil {
            // Nothing left to flush — what was assembled is the answer.
            text = assembler.transcript
        } else {
            request?.endAudio()
            let id = utteranceID
            text = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                var resumed = false
                finishResume = { value in
                    guard !resumed else { return }
                    resumed = true
                    c.resume(returning: value)
                }
                Task { [weak self] in
                    try? await Task.sleep(for: Self.finalGrace)
                    await self?.finalGraceElapsed(utterance: id)
                }
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

    private func readyRecognizer() async throws -> SFSpeechRecognizer {
        if !authorized {
            guard await Self.requestAuthorization() == .authorized else {
                throw TranscriberError.notAuthorized
            }
            authorized = true
        }
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        }
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        return recognizer
    }

    /// Opens a recognition task. The assembler keeps what earlier tasks heard.
    private func startTask() {
        guard let recognizer, let updates else { return }
        task?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = contextualStrings
        self.request = request

        taskSeq &+= 1
        let seq = taskSeq
        taskClosed = false
        task = recognizer.recognitionTask(with: request) { result, error in
            updates.yield(Update(
                task: seq,
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                failed: error != nil))
        }
    }

    private func apply(_ update: Update) {
        guard update.task == taskSeq else { return }
        if let text = update.text {
            assembler.update(text: text, isFinal: update.isFinal)
            partialContinuation?.yield(assembler.transcript)
        }
        guard update.isFinal || update.failed else { return }
        // Before endAudio, `append` reopens on the next buffer. Errors here are
        // routine ("no speech" after a pause); the words already heard stay.
        taskClosed = true
        if audioEnded { resolveFinish() }
    }

    private func finalGraceElapsed(utterance: UInt64) {
        guard utterance == utteranceID, finishResume != nil else { return }
        Self.log.notice("closing final missed the grace; using the assembled transcript")
        resolveFinish()
    }

    private func resolveFinish() {
        let resume = finishResume
        finishResume = nil
        resume?(assembler.transcript)
    }

    private func cleanupUtterance() {
        // A caller still waiting in finish() gets what was heard, never a hang.
        resolveFinish()
        task?.cancel()
        task = nil
        request = nil
        taskClosed = false
        updates?.finish()
        updates = nil
        updatesTask?.cancel()
        updatesTask = nil
        partialContinuation?.finish()
        partialContinuation = nil
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

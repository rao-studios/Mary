//
//  AnalyzerSpeechTranscriber.swift
//  MaryVoice
//
//  WHAT: Per-utterance STT on SpeechAnalyzer + SpeechTranscriber (macOS 26 model).
//  IN:   VoicePipeline (VoiceTranscriber) when STTBackend.analyzer
//  OUT:  partials stream + finish() transcript
//  PIN:  finish() flushes through end of input — the tail is finalized, not
//        guessed from a partial. The timer is a backstop for a wedged analyzer.
//  PIN:  Every buffer goes through AnalyzerFeed. Mic Float32 into the analyzer is a SIGTRAP.
//

import AVFoundation
import Foundation
import Speech
import os

public actor AnalyzerSpeechTranscriber: VoiceTranscriber {

    public enum Failure: LocalizedError {
        case noCompatibleFormat

        public var errorDescription: String? {
            "No audio format the on-device recognizer accepts is available."
        }
    }

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "voice.stt")
    /// Backstop only — a healthy flush lands well inside it.
    private static let flushGrace: Duration = .seconds(3)

    /// An analyzer ready to start: model installed, format chosen, prepared.
    private struct Prepared: @unchecked Sendable {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let analyzerFormat: AVAudioFormat
    }

    private struct Utterance {
        let analyzer: SpeechAnalyzer
        let feed: AnalyzerFeed
        let input: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<Void, Never>
    }

    private let locale: Locale
    /// Words the recognizer should prefer — her name, project names.
    private let contextualStrings: [String]

    /// Next utterance's analyzer, prepared ahead so `begin` only starts it.
    private var preparing: (format: AVAudioFormat, task: Task<Prepared, Error>)?
    private var lastFormat: AVAudioFormat?
    private var utterance: Utterance?
    private var utteranceID: UInt64 = 0
    private var assembler = TranscriptAssembler()
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var finishResume: ((String) -> Void)?

    public init(locale: Locale = .current, contextualStrings: [String] = []) {
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    // MARK: - VoiceTranscriber

    public func prewarm(format: AVAudioFormat) async {
        prepareAhead(for: format)
    }

    public func begin(format: AVAudioFormat) async throws {
        cleanupUtterance()
        let ready = try await takePreparation(for: format).value

        utteranceID &+= 1
        let id = utteranceID
        assembler = TranscriptAssembler()

        // Unbounded: the pre-roll replay lands at once, and a dropped head frame is the bug.
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await ready.analyzer.start(inputSequence: input)
        let transcriber = ready.transcriber
        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    // AttributedString carries timing; the transcript only wants words.
                    await self?.apply(
                        String(result.text.characters), isFinal: result.isFinal, utterance: id)
                }
            } catch {
                Self.log.error("analyzer results ended: \(error.localizedDescription)")
            }
        }
        utterance = Utterance(
            analyzer: ready.analyzer,
            feed: AnalyzerFeed(target: ready.analyzerFormat),
            input: continuation,
            results: results)
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let utterance, let converted = utterance.feed.convert(buffer) else { return }
        utterance.input.yield(AnalyzerInput(buffer: converted))
    }

    public func partials() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4))
        partialContinuation = continuation
        return stream
    }

    public func finish() async throws -> String {
        guard let utterance else { throw TranscriberError.noSpeech }
        utterance.input.finish()
        let id = utteranceID
        let analyzer = utterance.analyzer
        let results = utterance.results
        let text = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            var resumed = false
            finishResume = { value in
                guard !resumed else { return }
                resumed = true
                c.resume(returning: value)
            }
            Task { [weak self] in
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    Self.log.error("analyzer flush failed: \(error.localizedDescription)")
                }
                // Results drain after the flush; every finalized segment is in.
                await results.value
                await self?.flushSettled(utterance: id, timedOut: false)
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.flushGrace)
                await self?.flushSettled(utterance: id, timedOut: true)
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

    private func apply(_ text: String, isFinal: Bool, utterance id: UInt64) {
        guard id == utteranceID else { return }
        assembler.update(text: text, isFinal: isFinal)
        partialContinuation?.yield(assembler.transcript)
    }

    private func flushSettled(utterance id: UInt64, timedOut: Bool) {
        guard id == utteranceID, finishResume != nil else { return }
        if timedOut {
            Self.log.notice("analyzer flush missed the grace; using the assembled transcript")
        }
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
        partialContinuation?.finish()
        partialContinuation = nil
        guard let utterance else { return }
        self.utterance = nil
        utterance.input.finish()
        utterance.results.cancel()
        // Detached: a wedged Speech shutdown must not hold the next utterance.
        let analyzer = utterance.analyzer
        Task.detached(priority: .utility) { await analyzer.cancelAndFinishNow() }
        if let lastFormat { prepareAhead(for: lastFormat) }
    }

    private func prepareAhead(for format: AVAudioFormat) {
        lastFormat = format
        if let preparing, preparing.format == format { return }
        preparing?.task.cancel()
        preparing = (format, makePreparation(for: format))
    }

    private func takePreparation(for format: AVAudioFormat) -> Task<Prepared, Error> {
        lastFormat = format
        defer { preparing = nil }
        if let preparing, preparing.format == format { return preparing.task }
        preparing?.task.cancel()
        return makePreparation(for: format)
    }

    private func makePreparation(for format: AVAudioFormat) -> Task<Prepared, Error> {
        let locale = locale
        let strings = contextualStrings
        return Task {
            try await Self.prepare(locale: locale, contextualStrings: strings, inputFormat: format)
        }
    }

    private static func prepare(
        locale: Locale,
        contextualStrings: [String],
        inputFormat: AVAudioFormat
    ) async throws -> Prepared {
        guard await requestAuthorization() == .authorized else {
            throw TranscriberError.notAuthorized
        }
        // Volatile results feed partials; no fastResults — it trades accuracy for latency.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])
        try await SpeechModelAssets.ensureInstalled([transcriber], locale: locale)

        // Analyzer picks the format, not the mic. See AnalyzerFeed.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: inputFormat) else {
            throw Failure.noCompatibleFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            // Hints are best-effort; a refusal leaves recognition as it was.
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        return Prepared(analyzer: analyzer, transcriber: transcriber, analyzerFormat: analyzerFormat)
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

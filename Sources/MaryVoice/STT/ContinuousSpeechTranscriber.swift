//
//  ContinuousSpeechTranscriber.swift
//  MaryVoice
//
//  WHAT: Session-long SpeechAnalyzer transcript (volatile + finalized spans).
//  IN:   VoicePipeline+ContinuousHearing
//  OUT:  TranscriptSegment → IntakePlanner
//  PIN:  Does not replace the acoustic path; remember or offer, never take.
//

import AVFoundation
import Foundation
import Speech
import os

/// One span of recognized speech. Consumer: IntakePlanner / live caption.
public struct TranscriptSegment: Sendable, Equatable {
    public var text: String
    /// Recognizer will not revise these words.
    public var isFinalized: Bool
    /// When the span was received. Caller measures silence from here.
    public var receivedAt: Date

    public init(text: String, isFinalized: Bool, receivedAt: Date = Date()) {
        self.text = text
        self.isFinalized = isFinalized
        self.receivedAt = receivedAt
    }
}

/// Backend that recognizes across utterance boundaries. Separate from
/// VoiceTranscriber — per-utterance backends cannot honestly implement this.
public protocol ContinuousTranscribing: Sendable {
    /// Volatile + finalized spans for the whole session.
    func segments() async -> AsyncStream<TranscriptSegment>
    func beginSession(format: AVAudioFormat) async throws
    func appendContinuous(_ buffer: AVAudioPCMBuffer) async
    func endSession() async
}

public actor ContinuousSpeechTranscriber: ContinuousTranscribing {

    public enum Failure: LocalizedError {
        case notAuthorized
        case noCompatibleFormat

        public var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition is not authorized."
            case .noCompatibleFormat:
                return "No audio format the on-device recognizer accepts is available."
            }
        }
    }

    private static let log =
        Logger(subsystem: "nyc.rao.mary", category: "voice.continuous")

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Every buffer goes through AnalyzerFeed — crash fix, not an optimization.
    private var feed: AnalyzerFeed?
    private var segmentContinuations: [UUID: AsyncStream<TranscriptSegment>.Continuation] = [:]

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    // MARK: - Subscription

    /// Multi-subscriber (unlike AppleSpeechTranscriber.partials). Pipeline + UI caption.
    public func segments() async -> AsyncStream<TranscriptSegment> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TranscriptSegment>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        segmentContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropSubscriber(id) }
        }
        return stream
    }

    private func dropSubscriber(_ id: UUID) {
        segmentContinuations[id] = nil
    }

    private func emit(_ segment: TranscriptSegment) {
        for continuation in segmentContinuations.values { continuation.yield(segment) }
    }

    // MARK: - Session

    public func beginSession(format: AVAudioFormat) async throws {
        guard await Self.requestAuthorization() == .authorized else {
            throw Failure.notAuthorized
        }
        await endSession()

        // Progressive preset emits volatile + finalized — IntakePlanner needs that split.
        let transcriber = SpeechTranscriber(
            locale: locale, preset: .progressiveTranscription)

        // Model must be on the machine (and reserved) before the analyzer can use it.
        try await SpeechModelAssets.ensureInstalled([transcriber], locale: locale)

        // Analyzer picks the format, not the mic. See AnalyzerFeed.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: format) else {
            throw Failure.noCompatibleFormat
        }
        feed = AnalyzerFeed(target: analyzerFormat)

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: inputStream)

        self.transcriber = transcriber
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    // AttributedString carries timing; the decision only wants words.
                    let text = String(result.text.characters)
                    await self?.emit(TranscriptSegment(
                        text: text, isFinalized: result.isFinal))
                }
            } catch {
                Self.log.error("continuous STT stream ended: \(error.localizedDescription)")
            }
        }
    }

    public func appendContinuous(_ buffer: AVAudioPCMBuffer) {
        guard let inputContinuation, let feed else { return }
        guard let converted = feed.convert(buffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    public func endSession() async {
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            // Not finalizeAndFinishThroughEndOfInput — stop is not a last-flush request.
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        transcriber = nil
        feed = nil
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

//
//  ContinuousSpeechTranscriber.swift
//  MaryVoice
//
//  A TRANSCRIPT THAT SPANS THE WHOLE SESSION, not one utterance.
//
//  WHY A SECOND BACKEND RATHER THAN A CHANGE TO THE FIRST. `VoiceTranscriber`'s
//  contract is `begin → append… → finish`, one recognizer per utterance, and
//  `AppleSpeechTranscriber` implements it correctly: a fresh
//  `SFSpeechRecognitionTask` per open utterance, torn down at the endpoint.
//  Nothing in that shape can answer "what has been said in this room for the
//  last ten minutes", because by construction it stops listening between
//  utterances and forgets across them.
//
//  `SpeechAnalyzer` (macOS 26) is the API built for the other shape: one
//  analysis session over an unbounded input sequence, emitting VOLATILE
//  results that may be revised and FINALIZED ones that will not. That
//  distinction is the whole reason this file exists — `IntakePlanner` refuses
//  to act on a volatile span, and a recognizer without that signal cannot tell
//  a finished thought from a guess in progress.
//
//  IT DOES NOT REPLACE THE ACOUSTIC PATH. `VoicePipeline`'s VAD loop remains
//  the only thing that opens an utterance and submits a turn in the ordinary
//  case. This runs beside it, and everything it produces is either remembered
//  or offered — never taken.
//

import AVFoundation
import Foundation
import Speech
import os

/// One span of recognized speech, with the two facts a decision needs.
public struct TranscriptSegment: Sendable, Equatable {
    public var text: String
    /// The recognizer will not revise these words.
    public var isFinalized: Bool
    /// When the span was received. The caller measures silence from here —
    /// the analyzer reports media time, and the pipeline reasons in wall time.
    public var receivedAt: Date

    public init(text: String, isFinalized: Bool, receivedAt: Date = Date()) {
        self.text = text
        self.isFinalized = isFinalized
        self.receivedAt = receivedAt
    }
}

/// A backend that recognizes ACROSS utterance boundaries.
///
/// A separate protocol rather than a widened `VoiceTranscriber`, because the
/// per-utterance backends cannot honestly implement it — an utterance-final one
/// has no partials at all, and Apple's per-utterance recognizer forgets between
/// them. A defaulted method returning an empty stream would let a caller
/// believe it was listening continuously when nothing was.
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
        case localeUnsupported(String)
        case modelDownloading(String)
        case noCompatibleFormat

        public var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition is not authorized."
            case .localeUnsupported(let identifier):
                return "Continuous transcription is unavailable for \(identifier)."
            case .modelDownloading(let identifier):
                return "The on-device speech model for \(identifier) is still downloading."
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
    /// EVERY BUFFER GOES THROUGH HERE, never straight to the analyzer —
    /// see `AnalyzerFeed`, which is a crash fix, not an optimization.
    private var feed: AnalyzerFeed?
    private var segmentContinuations: [UUID: AsyncStream<TranscriptSegment>.Continuation] = [:]

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    // MARK: - Subscription

    /// MULTI-SUBSCRIBER, unlike `AppleSpeechTranscriber.partials()` — that one
    /// overwrites a single continuation, so a second subscriber silently
    /// steals the first's stream. Here the pipeline reads segments for intake
    /// while the UI may want the same spans for a live caption, and neither
    /// may starve the other.
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

        // PROGRESSIVE, not plain transcription: it is the preset that emits
        // volatile spans as well as finalized ones, and the volatile/finalized
        // split is the signal `IntakePlanner` refuses to act without.
        let transcriber = SpeechTranscriber(
            locale: locale, preset: .progressiveTranscription)

        // THE MODEL HAS TO BE ON THE MACHINE, and `status` is the question
        // that actually asks that.
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported:
            throw Failure.localeUnsupported(locale.identifier)
        case .supported:
            // Supported but absent — fetch it. A nil request means there is
            // nothing to fetch, which at this status means the OS declined;
            // re-checking below is what turns that into an honest error
            // rather than a silent no-op.
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]) {
                Self.log.info("continuous STT: downloading the on-device model")
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw Failure.modelDownloading(locale.identifier)
            }
        case .downloading:
            // Someone else already started it. Refusing now is better than
            // opening a session that will transcribe nothing until it lands.
            throw Failure.modelDownloading(locale.identifier)
        case .installed:
            break
        @unknown default:
            break
        }

        // RESERVING IS BEST-EFFORT, AND `false` IS NOT A FAILURE.
        //
        // THE BUG THIS FIXES (seen live, as "the on-device speech model could
        // not be reserved" on every launch but the first): `reserve` answers
        // "did THIS CALL take a slot", not "is this locale reserved". The
        // reservation outlives the process, so the first launch reserves and
        // returns true and every launch afterwards returns false — with the
        // model sitting installed and perfectly usable the whole time.
        // Treating that as fatal disabled continuous hearing permanently
        // after one successful run, which is the worst possible shape for a
        // bug: it works once, then never again, and the message blames the
        // model.
        //
        // It is also not released on `endSession`: reservations exist to keep
        // the model resident, and releasing one every time the mic stops would
        // thrash the very thing it is for.
        _ = try? await AssetInventory.reserve(locale: locale)

        // THE ANALYZER PICKS THE FORMAT, NOT THE MICROPHONE. Handing it the
        // mic's format instead is the SIGTRAP documented on `AnalyzerFeed`;
        // `considering:` asks for the one closest to the mic's, so the
        // conversion that follows stays as cheap as the hardware allows.
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
                    // `AttributedString` carries timing and confidence
                    // attributes; the decision only wants the words.
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
            // Not `finalizeAndFinishThroughEndOfInput`: a session stop is not
            // a request to flush a last transcript, and awaiting one would
            // hold the microphone teardown behind the recognizer.
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

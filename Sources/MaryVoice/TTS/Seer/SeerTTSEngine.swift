//
//  SeerTTSEngine.swift
//  MaryVoice
//
//  WHAT: Cloud synthesis via local Seer /v1/speak (header + float32 PCM).
//  IN:   KokoroStreamSpeaker (SpeechSynthesizer)
//  OUT:  SynthesizedChunk; Kokoro fallback on dead/401/5xx
//  PIN:  Auth via injected token provider. One emotion + gain per utterance.
//

import Foundation

public enum SeerTTSError: Error, LocalizedError, Equatable {
    case notSignedIn
    case badStatus(Int)
    case malformedHeader
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Seer — its voice needs a session."
        case .badStatus(let code):
            switch code {
            case 401: return "Seer rejected the session token (401)."
            case 502: return "Seer couldn't reach Mistral for speech (502)."
            default:  return "Seer speech failed with HTTP \(code)."
            }
        case .malformedHeader:
            return "Seer's audio stream was malformed."
        case .emptyAudio:
            return "Seer returned no audio for the chunk."
        }
    }
}

public actor SeerTTSEngine: SpeechSynthesizer {

    public static let defaultModel = "voxtral-mini-tts-2603"

    /// Rate of the most recent synthesis — normally the header's 24 kHz;
    /// reflects the fallback synthesizer when a chunk degraded to it.
    public private(set) var sampleRate: Double = 24_000

    /// The emotion the last chunk was spoken with — surfaced for probes/logs.
    public private(set) var lastEmotion: MarieEmotion = .neutral

    /// ONE emotion per utterance — classified on the first chunk, held for the rest.
    private var pinnedEmotion: MarieEmotion?

    /// Loudness twin of pinned emotion — from first chunk. See ChunkEdgeDSP.utteranceGain.
    private var pinnedGain: Float?

    public func beginUtterance() {
        pinnedEmotion = nil
        pinnedGain = nil
    }

    private var baseURL: URL
    private var character: VoiceCharacter
    private let model: String
    private let tokenProvider: @Sendable () async -> String?
    /// Carries a chunk when Seer can't (dead server, 401/5xx after retry).
    private var fallback: (any SpeechSynthesizer)?

    public init(
        baseURL: URL,
        character: VoiceCharacter = .marie,
        model: String = SeerTTSEngine.defaultModel,
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.baseURL = baseURL
        self.character = character
        self.model = model
        self.tokenProvider = tokenProvider
    }

    public func configure(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func setCharacter(_ character: VoiceCharacter) {
        self.character = character
    }

    public func setFallback(_ synthesizer: (any SpeechSynthesizer)?) {
        fallback = synthesizer
    }

    /// Host surfaces a degraded chunk (status note, never spoken).
    private var onDegrade: (@Sendable (String) -> Void)?

    public func setOnDegrade(_ callback: (@Sendable (String) -> Void)?) {
        onDegrade = callback
    }

    /// Host forces a genuine session refresh before an auth retry.
    private var onReauth: (@Sendable () async -> Void)?

    public func setOnReauth(_ callback: (@Sendable () async -> Void)?) {
        onReauth = callback
    }

    /// Fired once when Seer succeeds after degradation — re-arm the notice.
    private var onRecover: (@Sendable () -> Void)?
    private var degradedSinceLastSuccess = false

    public func setOnRecover(_ callback: (@Sendable () -> Void)?) {
        onRecover = callback
    }

    public func synthesizeWaveform(_ text: String) async throws -> [Float] {
        let chunk = try await synthesizeChunk(text)
        sampleRate = chunk.sampleRate
        return chunk.samples
    }

    /// Prefetch-safe: rate rides the return value. synthesizeWaveform is the wrapper.
    public func synthesizeChunk(_ text: String) async throws -> SynthesizedChunk {
        try Task.checkCancellation()
        do {
            let chunk = try await synthesizeViaSeer(text)
            noteSeerSuccess()
            return chunk
        } catch let firstError {
            try Self.propagateCancellation(firstError)
            // Auth-shaped failure: refresh session, retry once, then fallback.
            if isAuthShaped(firstError) {
                await onReauth?()
                // A refresh hook may ignore cancellation. Do not let it turn a
                // teardown into a brand-new token lookup/network request.
                try Task.checkCancellation()
                do {
                    let chunk = try await synthesizeViaSeer(text)
                    noteSeerSuccess()
                    return chunk
                } catch {
                    try Self.propagateCancellation(error)
                    return try await degrade(text, error: error)
                }
            }
            return try await degrade(text, error: firstError)
        }
    }

    private func noteSeerSuccess() {
        guard degradedSinceLastSuccess else { return }
        degradedSinceLastSuccess = false
        onRecover?()
    }

    private func isAuthShaped(_ error: Error) -> Bool {
        if case .notSignedIn = error as? SeerTTSError { return true }
        if case .badStatus(401) = error as? SeerTTSError { return true }
        return false
    }

    private func degrade(_ text: String, error: Error) async throws -> SynthesizedChunk {
        // Cancellation is teardown, never backend degradation.
        try Self.propagateCancellation(error)
        guard let fallback else { throw error }
        onDegrade?(error.localizedDescription)
        degradedSinceLastSuccess = true
        try Task.checkCancellation()
        let samples = try await fallback.synthesizeWaveform(text)
        let rate = await fallback.sampleRate
        sampleRate = rate
        return SynthesizedChunk(
            samples: samples, sampleRate: rate,
            pronunciation: await fallback.lastPronunciationReport)
    }

    /// Throw cancellation before retry/reauth/fallback. Check error and current task.
    private nonisolated static func propagateCancellation(_ error: Error) throws {
        if error is CancellationError { throw error }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            throw urlError
        }
        try Task.checkCancellation()
    }

    private func synthesizeViaSeer(_ text: String) async throws -> SynthesizedChunk {
        let token = await tokenProvider()
        // Token providers often bridge caches/callback APIs that do not throw
        // on cancellation. Re-check before building or starting the request.
        try Task.checkCancellation()
        guard let token else { throw SeerTTSError.notSignedIn }

        let emotion = pinnedEmotion
            ?? EmotionClassifier.classify(text, allowed: character.emotions)
        pinnedEmotion = emotion
        lastEmotion = emotion
        let request = try makeRequest(
            text: text, voiceID: character.voiceID(for: emotion), token: token)

        do {
            return try await performSynthesis(request)
        } catch let error where isRetryable(error) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try Task.checkCancellation()
            return try await performSynthesis(request)
        }
    }

    // MARK: - Request

    private struct SpeakRequestBody: Encodable {
        let model: String
        let input: String
        let voiceID: String
        let responseFormat: String

        enum CodingKeys: String, CodingKey {
            case model, input
            case voiceID = "voice_id"
            case responseFormat = "response_format"
        }
    }

    /// Internal: timeout it stamps is pinned by tests.
    func makeRequest(text: String, voiceID: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/speak"))
        request.httpMethod = "POST"
        request.timeoutInterval = SpeechStreamingHTTP.firstByteTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // `stream` is decoded but ignored server-side — Seer always streams.
        request.httpBody = try JSONEncoder().encode(SpeakRequestBody(
            model: model,
            input: text,
            voiceID: voiceID,
            responseFormat: "pcm"))
        return request
    }

    private func performSynthesis(_ request: URLRequest) async throws -> SynthesizedChunk {
        // Wall-clock-capped session (URLSession.shared resource ceiling is seven days).
        let (bytes, response) = try await SpeechStreamingHTTP.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SeerTTSError.badStatus(http.statusCode)
        }

        var payload = Data()
        for try await byte in bytes {
            payload.append(byte)
        }
        let (header, pcm) = try SeerPCMHeader.split(payload)
        let rate = Double(header.sampleRate)
        sampleRate = rate

        var samples = PCMBytes.floats(fromFloat32LE: pcm)
        guard !samples.isEmpty else { throw SeerTTSError.emptyAudio }
        // Each chunk is an independent server render with its own variable
        // dead air; trimming + micro-fades give the seams one even cadence.
        ChunkEdgeDSP.smoothEdges(&samples, sampleRate: rate)
        let gain = pinnedGain
            ?? ChunkEdgeDSP.utteranceGain(firstChunkPeak: ChunkEdgeDSP.peak(samples))
        pinnedGain = gain
        ChunkEdgeDSP.applyGain(&samples, gain: gain)
        return SynthesizedChunk(samples: samples, sampleRate: rate, pronunciation: nil)
    }

    /// Pure retry predicate — pinned by tests.
    nonisolated func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return false
            // Timeouts/refused hosts retry only doubles wait; Kokoro is ready. Transient faults retry.
            case .timedOut, .cannotConnectToHost, .cannotFindHost:
                return false
            default:
                return true
            }
        }
        if case .badStatus(let code) = error as? SeerTTSError {
            return code == 429 || (500...599).contains(code)
        }
        return false
    }
}

// MARK: - Wire header (internal, testable)

/// The 8-byte prefix Seer writes before the PCM: sampleRate UInt32 LE,
/// channels UInt16 LE, bits UInt16 LE (24000 / 1 / 32 today).
struct SeerPCMHeader: Equatable {
    var sampleRate: UInt32
    var channels: UInt16
    var bits: UInt16

    static func split(_ payload: Data) throws -> (header: SeerPCMHeader, pcm: Data) {
        guard payload.count >= 8 else { throw SeerTTSError.malformedHeader }
        let header = payload.withUnsafeBytes { raw -> SeerPCMHeader in
            SeerPCMHeader(
                sampleRate: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
                channels: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self)),
                bits: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self))
            )
        }
        guard header.channels == 1, header.bits == 32,
              header.sampleRate >= 8_000, header.sampleRate <= 96_000 else {
            throw SeerTTSError.malformedHeader
        }
        // Rebase the slice — PCMBytes.floats indexes from zero.
        return (header, Data(payload.dropFirst(8)))
    }
}

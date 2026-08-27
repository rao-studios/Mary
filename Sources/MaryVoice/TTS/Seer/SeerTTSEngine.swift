//
//  SeerTTSEngine.swift
//  MaryVoice
//
//  Cloud synthesis through the local Seer server's /v1/speak proxy — the
//  one hosted voice, and the only one. Seer transcodes
//  Mistral's SSE server-side, so the reply here is simpler: an 8-byte
//  little-endian header (sampleRate UInt32, channels UInt16, bits UInt16)
//  followed by raw float32 mono PCM, streamed as it's generated.
//
//  MaryVoice stays domain-free: auth arrives via an injected bearer-token
//  provider. A missing MISTRAL_API_KEY on the server side kills the whole
//  Seer process (fatalError in its key getter) — so a dead connection is an
//  expected failure mode here, handled like any bad status: one retry, then
//  the injected fallback synthesizer (Kokoro) carries the chunk.
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

    /// ONE EMOTION PER UTTERANCE. Classified on the first chunk of a reply
    /// and held for the rest, because each emotion is a DIFFERENT wire voice
    /// — per-chunk classification flipped one paragraph between renditions
    /// mid-passage, which the ear hears as the character changing.
    private var pinnedEmotion: MarieEmotion?

    /// The loudness twin of the pinned emotion — computed from the first
    /// chunk, constant for the reply. See `ChunkEdgeDSP.utteranceGain`.
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

    /// Told once per degraded chunk — the host surfaces it (a status note,
    /// never a spoken interruption). Without it the fallback was total
    /// silence: settings said Seer, the ear heard Kokoro, and nothing
    /// anywhere said why.
    private var onDegrade: (@Sendable (String) -> Void)?

    public func setOnDegrade(_ callback: (@Sendable (String) -> Void)?) {
        onDegrade = callback
    }

    /// Told when an auth-shaped failure is about to earn its second attempt —
    /// the host forces a genuine session refresh so the retry carries a NEW
    /// token. Without it the retry re-read the session's CACHE: a token the
    /// server had rejected but that looked locally unexpired (server restart,
    /// new signing key, revoked session) was resent byte-identical, failed
    /// identically, and every chunk fell to the fallback voice forever.
    private var onReauth: (@Sendable () async -> Void)?

    public func setOnReauth(_ callback: (@Sendable () async -> Void)?) {
        onReauth = callback
    }

    /// Fired once when a Seer chunk succeeds after one or more degraded
    /// chunks — the host re-arms its once-per-episode degradation notice, so
    /// the SECOND outage is as visible as the first.
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

    /// THE PREFETCH-SAFE ENTRY POINT: the rate rides the return value, so two
    /// chunks in flight on this reentrant actor cannot read each other's
    /// rate off shared state. `synthesizeWaveform` is the legacy wrapper.
    public func synthesizeChunk(_ text: String) async throws -> SynthesizedChunk {
        try Task.checkCancellation()
        do {
            let chunk = try await synthesizeViaSeer(text)
            noteSeerSuccess()
            return chunk
        } catch let firstError {
            try Self.propagateCancellation(firstError)
            // SEER MEANS SEER: an auth-shaped failure gets one full second
            // attempt — with the session FORCED to refresh first, so the
            // retry carries a new token rather than the rejected one — before
            // any fallback is considered.
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
        // Cancellation is teardown, never backend degradation. In particular,
        // URLSession reports a cancelled request as `URLError.cancelled`; the
        // old catch-all path interpreted that as a dead Seer and launched a
        // fresh Kokoro render while the caller was trying to silence audio.
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

    /// Throw cancellation before any retry/reauth/fallback policy sees it.
    /// Checking both the concrete error and the current task closes the race
    /// where a collaborator returns its own ordinary error just after the
    /// parent task was cancelled.
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

    /// Internal, not private: the timeout it stamps is a live-incident fix and
    /// is pinned by tests (see the "Wire header" note below for the same
    /// reasoning applied to the header parser).
    func makeRequest(text: String, voiceID: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/speak"))
        request.httpMethod = "POST"
        // The IDLE gap between bytes — which for the FIRST byte is exactly the
        // "is this server alive?" question, and the one that must be answered
        // inside the caller's speaking budget rather than the 60 s that used to
        // sit here. It resets on every byte, so a stream genuinely delivering
        // audio is never cut by it.
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
        // Wall-clock-capped session: `URLSession.shared`'s resource ceiling is
        // seven days, and this is the path EVERY spoken sentence takes.
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

    /// Internal and `nonisolated`, not private: it is a PURE predicate over its
    /// argument — which failures are worth a second attempt — and that policy
    /// sits in front of a waiting listener, so it is pinned by tests.
    nonisolated func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return false
            // A SERVER THAT JUST TIMED OUT WILL TIME OUT AGAIN, and a host that
            // refused the connection will refuse it again — retrying only
            // doubles the wait in front of a listener while the on-device
            // fallback stands ready to speak the same chunk immediately.
            // Retries are for TRANSIENT faults (a dropped connection, a network
            // blip), which is what the remaining codes are.
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

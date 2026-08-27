//
//  SpeechStreamingHTTP.swift
//  MaryVoice
//
//  ONE RULE, the same one MaryBrain's `Engine/StreamingHTTP` states for the
//  chat transports: a streaming HTTP response must have a WALL CLOCK on it,
//  not only an idle timer.
//
//  THE FAILURE THIS PREVENTS. Both cloud voices — `SeerTTSEngine` (the shipped
//  path: `ttsBackend` defaults to `.seer`, so EVERY spoken sentence goes
//  through it) — streamed on `URLSession.shared` with
//  `request.timeoutInterval = 60` and nothing else. That number is
//  `timeoutIntervalForRequest`, which is an IDLE timer: it measures the gap
//  between bytes and resets on every one of them, so a server trickling PCM,
//  heartbeats, or SSE frames carrying no audio resets it forever. The wall
//  clock that would catch it, `timeoutIntervalForResource`, lives on the
//  session CONFIGURATION — a `URLRequest` has no such field — and
//  `URLSession.shared`'s is SEVEN DAYS. A wedged voice server could therefore
//  stop the reply mid-sentence and hold the speaker's Stage A open
//  indefinitely, with a bound everyone believed in and nobody had.
//
//  A SEPARATE COPY RATHER THAN A SHARED ONE, and the reason is the package
//  graph, not taste: MaryBrain depends on MaryVoice, so MaryVoice cannot
//  reach `StreamingHTTP` without a cycle. The two numbers below are therefore
//  stated here with their own arithmetic — which they need anyway, because a
//  sentence of speech and a round of Skill invocations are not the same request.
//

import Foundation

enum SpeechStreamingHTTP {

    /// IDLE timeout — the gap between bytes, and DELIBERATELY UNCHANGED at the
    /// 60 s both engines already carried. It is right for speech and wrong for
    /// chat: a TTS request is one sentence of at most `maxWordsPerChunk` words
    /// and its first byte should arrive inside a second, so a full minute of
    /// nothing is already far past dead. It was never the thing that bounded a
    /// hung stream, which is what the ceiling below is for.
    static let idleTimeout: TimeInterval = 60

    /// FIRST-BYTE (and inter-byte) bound for a single spoken chunk.
    ///
    /// FOUR SECONDS, and it follows from the paragraph above rather than
    /// contradicting it: a healthy local Seer answers a ≤30-word chunk in well
    /// under a second, so four is already generous, and `timeoutInterval` is an
    /// IDLE timer — it cannot cut a stream that is actually delivering audio.
    ///
    /// THE FAILURE THIS FIXES (live): a wedged Seer that accepts the socket and
    /// sends nothing cost 30 s (the resource ceiling), a 300 ms backoff, and
    /// another 30 s — while the caller speaking Mary's goodbye had budgeted
    /// twelve seconds for synthesis AND playback. Sixty is not less than
    /// twelve. The Kokoro fallback stands directly behind this call and can
    /// speak the chunk now, so failing fast is strictly better than waiting.
    static let firstByteTimeout: TimeInterval = 4

    /// WALL CLOCK for the whole request, first byte to last.
    ///
    /// THIRTY SECONDS, and it is arithmetic. One chunk is at most
    /// `KokoroStreamSpeaker.maxWordsPerChunk` (30) words — a few seconds of
    /// audio, generated faster than it plays — so this is roughly ten times the
    /// longest healthy synthesis. Both engines retry ONCE on a transient fault
    /// after a 300 ms backoff, so the worst a listener waits for one sentence
    /// is 2 × 30 s + 0.3 s ≈ the sixty seconds everyone already believed a
    /// chunk was capped at. The ceiling is now the binding number rather than
    /// the idle timer, exactly as in `StreamingHTTP`.
    static let resourceTimeout: TimeInterval = 30

    /// The session both cloud voices stream on. Deliberately shared rather than
    /// per-call: a `URLSession` per request leaks the connection pool and
    /// defeats keep-alive, and one sentence per request makes keep-alive the
    /// difference between a warm socket and a TLS handshake per sentence.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // A voice that cannot reach the network must FAIL, not wait: the
        // synthesizer's fallback (Kokoro, on-device) is standing right behind
        // it and can speak the chunk now.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

//
//  SpeechSynthesizer.swift
//  MaryVoice
//
//  The seam between the stream speaker's chunking/playback harness and
//  whatever turns a sentence into audio. Kokoro synthesizes on-device;
//  SeerTTSEngine calls the cloud. Both hand back mono float PCM plus
//  the rate it was rendered at — playback resamples to hardware.
//

import Foundation

public protocol SpeechSynthesizer: Actor {
    /// The full waveform for one sentence-chunk of text.
    func synthesizeWaveform(_ text: String) async throws -> [Float]

    /// Sample rate (Hz) of the most recent synthesis. Read after
    /// `synthesizeWaveform` so per-chunk model/rate switches are honored.
    var sampleRate: Double { get }

    /// Pronunciation trace for the last chunk; nil for backends without one.
    var lastPronunciationReport: PronunciationReport? { get }

    /// A NEW UTTERANCE (one pipeline run of the stream speaker — one reply)
    /// is starting. Engines reset per-utterance state here: the pinned
    /// emotion, a pinned gain. Default no-op, so on-device engines and stubs
    /// are untouched.
    ///
    /// THE FAILURE THIS SEAM FIXES: emotion was classified per two-sentence
    /// chunk, and each emotion is a DIFFERENT wire voice — one long reply
    /// flipped between neutral/curious/excited renditions mid-passage, which
    /// the ear hears as the character changing rhythm. One utterance, one
    /// classification, one voice.
    func beginUtterance()

    /// One chunk's complete synthesis result, carried together — the
    /// prefetch-safe entry point. A protocol REQUIREMENT (not only an
    /// extension convenience) so an engine's own implementation is reached
    /// through the existential; the extension default forwards to the legacy
    /// serialized path for engines that don't overlap.
    func synthesizeChunk(_ text: String) async throws -> SynthesizedChunk
}

extension SpeechSynthesizer {
    public var lastPronunciationReport: PronunciationReport? { nil }
    public func beginUtterance() {}
}

/// One chunk's complete synthesis result, carried TOGETHER — the shape that
/// makes prefetch safe. The legacy contract read `sampleRate` and
/// `lastPronunciationReport` AFTER `synthesizeWaveform`, which races the
/// moment two chunks are in flight on a reentrant actor; a per-call value
/// has nothing shared to race on.
public struct SynthesizedChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let pronunciation: PronunciationReport?

    public init(samples: [Float], sampleRate: Double, pronunciation: PronunciationReport?) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.pronunciation = pronunciation
    }
}

extension SpeechSynthesizer {
    /// Default: the legacy serialized semantics — correct for on-device
    /// engines (compute-bound, nothing gained from overlap) and for stubs.
    /// Cloud engines override so overlapping calls return consistent
    /// per-call rates.
    public func synthesizeChunk(_ text: String) async throws -> SynthesizedChunk {
        let samples = try await synthesizeWaveform(text)
        return SynthesizedChunk(
            samples: samples,
            sampleRate: sampleRate,
            pronunciation: lastPronunciationReport)
    }
}

// KokoroEngine already exposes all three members verbatim.
extension KokoroEngine: SpeechSynthesizer {}

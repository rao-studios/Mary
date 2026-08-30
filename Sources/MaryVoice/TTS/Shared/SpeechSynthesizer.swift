//
//  SpeechSynthesizer.swift
//  MaryVoice
//
//  WHAT: Seam between stream-speaker chunking and a sentence→PCM engine.
//  IN:   KokoroStreamSpeaker
//  OUT:  KokoroEngine / SeerTTSEngine → SynthesizedChunk
//

import Foundation

public protocol SpeechSynthesizer: Actor {
    /// Full waveform for one sentence-chunk.
    func synthesizeWaveform(_ text: String) async throws -> [Float]

    /// Sample rate (Hz) of the most recent synthesis. Read after synthesizeWaveform.
    var sampleRate: Double { get }

    /// Pronunciation trace for the last chunk; nil for backends without one.
    var lastPronunciationReport: PronunciationReport? { get }

    /// New utterance starting. Engines reset pinned emotion/gain. Default no-op.
    func beginUtterance()

    /// One chunk's complete result — prefetch-safe. Protocol requirement so
    /// an engine's override is reached through the existential.
    func synthesizeChunk(_ text: String) async throws -> SynthesizedChunk
}

extension SpeechSynthesizer {
    public var lastPronunciationReport: PronunciationReport? { nil }
    public func beginUtterance() {}
}

/// One chunk's complete result, carried together — prefetch-safe (no shared rate race).
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
    /// Default: legacy serialized path. Cloud engines override for overlap.
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

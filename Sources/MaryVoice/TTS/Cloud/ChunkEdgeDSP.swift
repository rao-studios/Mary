//
//  ChunkEdgeDSP.swift
//  MaryVoice
//
//  WHAT: Trim + fade seams between independent cloud /v1/speak chunks.
//  IN:   SeerTTSEngine after decode
//  OUT:  even cadence PCM (never applied to Kokoro or realtime stream)
//
//    1. trimSilence — drop edge samples below dBFS, keep a guard pad
//    2. edgeFades    — short linear ramps at both edges
//

import Accelerate
import Foundation

enum ChunkEdgeDSP {

    /// Trim threshold: −50 dBFS. Room tone below; quietest voiced onset above.
    static let defaultThresholdDb: Float = -50

    /// Guard inside each trimmed edge so a plosive's run-up survives.
    static let defaultGuardMs: Double = 10

    /// Fade length — long enough to kill a click, too short to hear.
    static let defaultFadeMs: Double = 6

    /// Scan hop for edge detection.
    private static let windowMs: Double = 5

    /// Trim leading/trailing silence. All-silent keeps guard pads (do not vanish).
    static func trimSilence(
        _ samples: inout [Float],
        sampleRate: Double,
        thresholdDb: Float = defaultThresholdDb,
        guardMs: Double = defaultGuardMs
    ) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        let threshold = pow(10, thresholdDb / 20)
        let window = max(1, Int(sampleRate * windowMs / 1_000))
        let guardSamples = Int(sampleRate * guardMs / 1_000)

        func firstLoudWindow(from indices: StrideTo<Int>) -> Int? {
            for start in indices {
                let length = min(window, samples.count - start)
                guard length > 0 else { continue }
                var peak: Float = 0
                samples.withUnsafeBufferPointer { buffer in
                    vDSP_maxmgv(buffer.baseAddress! + start, 1, &peak, vDSP_Length(length))
                }
                if peak >= threshold { return start }
            }
            return nil
        }

        guard let loudStart = firstLoudWindow(
            from: stride(from: 0, to: samples.count, by: window)) else {
            // All silence: keep a guard-pad beat rather than vanishing.
            let keep = min(samples.count, max(guardSamples, 1))
            samples = Array(samples.prefix(keep))
            return
        }
        var loudEnd = samples.count
        for start in stride(from: samples.count - window, through: 0, by: -window) {
            let length = min(window, samples.count - start)
            guard length > 0 else { continue }
            var peak: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                vDSP_maxmgv(buffer.baseAddress! + max(start, 0), 1, &peak, vDSP_Length(length))
            }
            if peak >= threshold { loudEnd = min(start + window, samples.count); break }
        }

        let lower = max(0, loudStart - guardSamples)
        let upper = min(samples.count, loudEnd + guardSamples)
        guard lower < upper else { return }
        samples = Array(samples[lower..<upper])
    }

    /// Linear fade-in/out. No-op on chunks shorter than two fades.
    static func edgeFades(
        _ samples: inout [Float],
        sampleRate: Double,
        ms: Double = defaultFadeMs
    ) {
        guard sampleRate > 0 else { return }
        let fade = Int(sampleRate * ms / 1_000)
        guard fade > 0, samples.count >= fade * 2 else { return }
        for index in 0..<fade {
            let gain = Float(index) / Float(fade)
            samples[index] *= gain
            samples[samples.count - 1 - index] *= gain
        }
    }

    /// Cloud-chunk chain, in order.
    static func smoothEdges(_ samples: inout [Float], sampleRate: Double) {
        trimSilence(&samples, sampleRate: sampleRate)
        edgeFades(&samples, sampleRate: sampleRate)
    }

    /// Absolute peak, for the per-utterance gain pin.
    static func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            vDSP_maxmgv(base, 1, &value, vDSP_Length(buffer.count))
        }
        return value
    }

    /// Loudness pinned per utterance, never per chunk. From first chunk toward 0.9 peak.
    static func utteranceGain(firstChunkPeak: Float) -> Float {
        guard firstChunkPeak > 0 else { return 1 }
        return min(max(0.9 / firstChunkPeak, 1), 2)
    }

    static func applyGain(_ samples: inout [Float], gain: Float) {
        guard gain != 1 else { return }
        var factor = gain
        vDSP_vsmul(samples, 1, &factor, &samples, 1, vDSP_Length(samples.count))
    }
}

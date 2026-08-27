//
//  ChunkEdgeDSP.swift
//  MaryVoice
//
//  THE SEAMS BETWEEN CLOUD CHUNKS, EVENED OUT. Every classic-route chunk is
//  an independent /v1/speak render, and each render arrives with its own
//  variable leading/trailing silence — so the gaps between spoken sentences
//  wobbled with whatever dead air the server happened to include, which the
//  ear hears as an uneven cadence. Kokoro trims model-side
//  (`audio_length_samples`); cloud PCM had no trim at all.
//
//  Two pure operations, applied by the CLOUD engines after decode (never to
//  Kokoro output — already trimmed and DSP'd — and never to the realtime
//  stream, which is one continuous render with no seams):
//
//    1. `trimSilence`  — drop edge samples below a dBFS threshold, keeping a
//                        small guard pad so consonant onsets survive.
//    2. `edgeFades`    — short linear ramps at both edges, killing the clicks
//                        a hard trim can expose.
//

import Accelerate
import Foundation

enum ChunkEdgeDSP {

    /// The trim threshold: −50 dBFS ≈ 0.00316 linear. Room tone and codec
    /// noise sit below it; the quietest voiced onset sits above.
    static let defaultThresholdDb: Float = -50

    /// What survives inside each trimmed edge, so a plosive's run-up is not
    /// clipped to nothing.
    static let defaultGuardMs: Double = 10

    /// Fade length. Long enough to kill a click, far too short to hear.
    static let defaultFadeMs: Double = 6

    /// The scan hop for edge detection.
    private static let windowMs: Double = 5

    /// Trim leading and trailing silence in place. An all-silent chunk trims
    /// to its guard pads rather than to nothing — a vanished chunk would
    /// close the gap entirely and weld two sentences together.
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
            // All silence: keep the guard pads' worth from the front so the
            // chunk still occupies a beat rather than vanishing.
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

    /// Linear fade-in/out in place. A no-op on chunks shorter than two fades
    /// — ramping most of a tiny chunk would just duck it.
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

    /// The cloud-chunk chain, in order.
    static func smoothEdges(_ samples: inout [Float], sampleRate: Double) {
        trimSilence(&samples, sampleRate: sampleRate)
        edgeFades(&samples, sampleRate: sampleRate)
    }

    /// The absolute peak, for the per-utterance gain pin.
    static func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            vDSP_maxmgv(base, 1, &value, vDSP_Length(buffer.count))
        }
        return value
    }

    /// LOUDNESS, PINNED PER UTTERANCE — never per chunk. Kokoro chunks leave
    /// their DSP chain peak-normalized to 1.0; cloud PCM arrives at server
    /// level, so a degraded chunk jumped loudness mid-passage. The gain is
    /// computed ONCE from the utterance's first chunk (toward a 0.9 peak,
    /// capped at +6 dB, never attenuating) and applied to every later chunk
    /// of the same utterance — per-chunk normalization would itself pump
    /// quiet and loud sentences against each other.
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

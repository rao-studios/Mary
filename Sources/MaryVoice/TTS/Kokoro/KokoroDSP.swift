//
//  KokoroDSP.swift
//  MaryVoice
//
//  WHAT: Post-process raw Float waveform before AVAudioPCMBuffer.
//  IN:   KokoroEngine.synthesizeWaveform
//  OUT:  peakNormalize → removeRumble → deEss
//

import Accelerate
import Foundation

enum KokoroDSP {

    // MARK: - Public chain

    /// Full post-processing chain. Mutates samples in place.
    static func applyPostProcessing(
        _ samples: inout [Float],
        sampleRate: Float = 24_000
    ) {
        peakNormalize(&samples)
        removeRumble(&samples, sampleRate: sampleRate, cutoffHz: 80)
        deEss(&samples, sampleRate: sampleRate, cutoffHz: 6_000, reductionDb: -3.0)
    }

    // MARK: - Rumble removal

    /// One-pole high-pass: y[n] = α * (y[n-1] + x[n] − x[n-1]). Removes DC/rumble.
    static func removeRumble(
        _ samples: inout [Float],
        sampleRate: Float = 24_000,
        cutoffHz: Float = 80
    ) {
        guard samples.count > 1 else { return }
        let rc    = 1.0 / (2.0 * Float.pi * cutoffHz)
        let dt    = 1.0 / sampleRate
        let alpha = rc / (rc + dt)
        var prevX = samples[0]
        var prevY: Float = 0
        for i in 1..<samples.count {
            let x    = samples[i]
            let y    = alpha * (prevY + x - prevX)
            samples[i] = y
            prevX = x
            prevY = y
        }
    }

    // MARK: - De-esser

    /// Biquad high-shelf, Direct Form II Transposed (Audio EQ Cookbook).
    static func deEss(
        _ samples: inout [Float],
        sampleRate: Float = 24_000,
        cutoffHz: Float = 6_000,
        reductionDb: Float = -3.0
    ) {
        guard samples.count > 2 else { return }

        let A        = powf(10, reductionDb / 40)          // linear amplitude shelf gain
        let omega    = 2 * Float.pi * cutoffHz / sampleRate
        let sinW     = sin(omega)
        let cosW     = cos(omega)
        let Q: Float = 0.707                               // Butterworth
        let alpha    = sinW / (2 * Q)
        let sqrtA    = sqrt(A)

        // High-shelf biquad numerator/denominator
        let b0 =  A * ((A + 1) + (A - 1) * cosW + 2 * sqrtA * alpha)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cosW)
        let b2 =  A * ((A + 1) + (A - 1) * cosW - 2 * sqrtA * alpha)
        let a0 =       (A + 1) - (A - 1) * cosW + 2 * sqrtA * alpha
        let a1 =  2 * ((A - 1) - (A + 1) * cosW)
        let a2 =       (A + 1) - (A - 1) * cosW - 2 * sqrtA * alpha

        // Normalise by a0
        let b0n = b0 / a0;  let b1n = b1 / a0;  let b2n = b2 / a0
        let a1n = a1 / a0;  let a2n = a2 / a0

        // Apply — Direct Form II Transposed
        var z1: Float = 0
        var z2: Float = 0
        for i in 0..<samples.count {
            let x    = samples[i]
            let y    = b0n * x + z1
            z1 = b1n * x - a1n * y + z2
            z2 = b2n * x - a2n * y
            samples[i] = y
        }
    }

    // MARK: - Peak normalization

    /// Normalize peak to 1.0 using vDSP.
    static func peakNormalize(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 1e-8 else { return }
        var normalized = [Float](repeating: 0, count: samples.count)
        vDSP_vsdiv(samples, 1, &peak, &normalized, 1, vDSP_Length(samples.count))
        samples = normalized
    }
}

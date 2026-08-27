//
//  ChunkEdgeDSPTests.swift
//  MaryVoiceTests
//
//  The seam-evening chain, pinned pure: cloud chunks arrive with variable
//  dead air on both edges; after the trim every seam carries the same small
//  guard pad, and the fades kill the clicks a hard trim exposes.
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct ChunkEdgeDSPTests {

    private let rate: Double = 24_000

    /// 300 ms silence + 100 ms tone + 200 ms silence.
    private func padded() -> [Float] {
        let silence = [Float](repeating: 0, count: Int(rate) * 3 / 10)
        let tone = (0..<Int(rate) / 10).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        let tail = [Float](repeating: 0, count: Int(rate) / 5)
        return silence + tone + tail
    }

    @Test func trimRemovesLeadingAndTrailingSilence() {
        var samples = padded()
        let toneLength = Int(rate) / 10
        ChunkEdgeDSP.trimSilence(&samples, sampleRate: rate)
        let guardPad = Int(rate * ChunkEdgeDSP.defaultGuardMs / 1_000)
        // The tone plus at most two guard pads and two scan windows.
        let window = Int(rate * 5 / 1_000)
        #expect(samples.count >= toneLength)
        #expect(samples.count <= toneLength + 2 * (guardPad + window))
    }

    @Test func theGuardPadIsKept() {
        var samples = padded()
        ChunkEdgeDSP.trimSilence(&samples, sampleRate: rate)
        // The first samples are inside the guard pad — silence kept on
        // purpose so a consonant's run-up survives.
        #expect(abs(samples.first ?? 1) < 0.01)
    }

    @Test func fadesRampTheEdgesToZero() {
        var samples = [Float](repeating: 0.8, count: Int(rate) / 4)
        ChunkEdgeDSP.edgeFades(&samples, sampleRate: rate)
        #expect(samples.first == 0)
        #expect(samples.last == 0)
        // The middle is untouched.
        #expect(samples[samples.count / 2] == 0.8)
    }

    @Test func shortChunksSurviveFadesUntouched() {
        var samples = [Float](repeating: 0.5, count: 8)
        ChunkEdgeDSP.edgeFades(&samples, sampleRate: rate)
        #expect(samples == [Float](repeating: 0.5, count: 8))
    }

    @Test func anAllSilentChunkNeverTrimsToEmpty() {
        var samples = [Float](repeating: 0, count: Int(rate))
        ChunkEdgeDSP.trimSilence(&samples, sampleRate: rate)
        #expect(!samples.isEmpty, "a vanished chunk welds two sentences together")
    }
}

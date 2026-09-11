//
//  EnergyVADTests.swift
//  MaryVoiceTests
//
//  WHAT: Energy endpointing — open, hysteresis, hangover, noise, boost, and
//        the unfinished-phrase extension.
//  OUT:  EnergyVAD
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct EnergyVADTests {

    private func makeVAD() -> EnergyVAD {
        EnergyVAD(config: VADConfig(
            speechStartRMS: 0.015,
            speechContinueRMS: 0.008,
            hangoverMs: 850,
            minUtteranceMs: 300,
            bargeInRMSBoost: 3.0
        ))
    }

    private let frame = 0.02  // 20 ms frames

    private func speak(_ vad: EnergyVAD, frames: Int) {
        for _ in 0..<frames { _ = vad.process(rms: 0.05, frameDuration: frame) }
    }

    @Test func silenceNeverOpens() {
        let vad = makeVAD()
        for _ in 0..<200 {
            #expect(vad.process(rms: 0.001, frameDuration: frame) == .none)
        }
        #expect(!vad.isSpeechActive)
    }

    @Test func loudFrameOpensUtterance() {
        let vad = makeVAD()
        #expect(vad.process(rms: 0.05, frameDuration: frame) == .speechStart)
        #expect(vad.isSpeechActive)
    }

    @Test func hysteresisKeepsSoftSyllablesAlive() {
        let vad = makeVAD()
        _ = vad.process(rms: 0.05, frameDuration: frame)
        // Between continue (0.008) and start (0.015): stays open.
        #expect(vad.process(rms: 0.010, frameDuration: frame) == .none)
        #expect(vad.isSpeechActive)
    }

    @Test func hangoverClosesUtterance() {
        let vad = makeVAD()
        speak(vad, frames: 26)
        // Silence: nothing until the 850 ms hangover elapses.
        var verdicts: [VADVerdict] = []
        for _ in 0..<50 {
            verdicts.append(vad.process(rms: 0.001, frameDuration: frame))
        }
        let ends = verdicts.compactMap { verdict -> TimeInterval? in
            if case .speechEnd(let duration) = verdict { return duration }
            return nil
        }
        #expect(ends.count == 1)
        // ~520 ms voiced (26 frames), hangover excluded.
        #expect(abs(ends[0] - 0.52) < 0.05)
        #expect(!vad.isSpeechActive)
    }

    @Test func shortBurstDiscardedAsNoise() {
        let vad = makeVAD()
        _ = vad.process(rms: 0.05, frameDuration: frame)  // 20 ms of "speech"
        var sawDiscard = false
        for _ in 0..<60 {
            if vad.process(rms: 0.001, frameDuration: frame) == .discardedNoise {
                sawDiscard = true
            }
        }
        #expect(sawDiscard)
    }

    @Test func boostRaisesThreshold() {
        let vad = makeVAD()
        vad.thresholdBoost = 3.0
        // 0.02 clears the normal 0.015 start but not the boosted 0.045.
        #expect(vad.process(rms: 0.02, frameDuration: frame) == .none)
        #expect(vad.process(rms: 0.05, frameDuration: frame) == .speechStart)
    }

    // MARK: - Unfinished-phrase extension

    /// "open the … Safari window": the pause after "the" is not the end.
    @Test func extensionHoldsAnUnfinishedPhraseOpen() {
        let vad = makeVAD()
        speak(vad, frames: 26)
        vad.hangoverExtension = 0.7
        // 1.2 s of silence: past the 850 ms hangover, inside 850 + 700.
        for _ in 0..<60 {
            #expect(vad.process(rms: 0.001, frameDuration: frame) == .none)
        }
        #expect(vad.isSpeechActive)

        var ended = false
        for _ in 0..<20 {
            if case .speechEnd = vad.process(rms: 0.001, frameDuration: frame) { ended = true }
        }
        #expect(ended, "the held pause still ends")
        #expect(vad.hangoverExtension == 0, "cleared with the utterance it held")
    }

    @Test func resetClearsTheExtension() {
        let vad = makeVAD()
        vad.hangoverExtension = 0.7
        vad.reset()
        #expect(vad.hangoverExtension == 0)
    }

    @Test func aStaleExtensionDoesNotReachTheNextUtterance() {
        let vad = makeVAD()
        vad.hangoverExtension = 0.7   // a late partial after the last close
        #expect(vad.process(rms: 0.05, frameDuration: frame) == .speechStart)
        #expect(vad.hangoverExtension == 0)
    }
}

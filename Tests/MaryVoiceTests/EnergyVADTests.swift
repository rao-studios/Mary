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
            preRollMs: 300,
            bargeInRMSBoost: 3.0
        ))
    }

    private let frame = 0.02  // 20 ms frames

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
        _ = vad.process(rms: 0.05, frameDuration: frame)
        // 500 ms of voiced speech.
        for _ in 0..<25 {
            _ = vad.process(rms: 0.05, frameDuration: frame)
        }
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
}

import Foundation
import Testing
@testable import MaryVoice

@Suite struct BargeInGovernorTests {

    private func governor() -> BargeInGovernor {
        // onset 0.045 (0.015 × 3), commit 300ms, retreat 500ms
        BargeInGovernor(onsetRMS: 0.045, commitAfter: 0.3, retreatAfter: 0.5)
    }

    private let frame: TimeInterval = 0.021   // ~1024 samples at 48kHz

    @Test func firstLoudFramePausesImmediately() {
        var g = governor()
        #expect(g.process(rms: 0.01, frameDuration: frame) == .none)
        #expect(g.process(rms: 0.05, frameDuration: frame) == .pause)
        #expect(g.isProvisional)
    }

    @Test func sustainedSpeechCommits() {
        var g = governor()
        #expect(g.process(rms: 0.05, frameDuration: frame) == .pause)
        var last = BargeInGovernor.Action.none
        for _ in 0..<20 {   // 20 × 21ms ≈ 420ms voiced
            last = g.process(rms: 0.05, frameDuration: frame)
            if last == .commit { break }
        }
        #expect(last == .commit)
        #expect(!g.isProvisional)
    }

    @Test func briefNoiseRetreatsAndResumes() {
        var g = governor()
        #expect(g.process(rms: 0.06, frameDuration: frame) == .pause)
        // Two loud frames (~42ms — a cough), then quiet.
        _ = g.process(rms: 0.06, frameDuration: frame)
        var last = BargeInGovernor.Action.none
        for _ in 0..<30 {   // ~630ms of quiet
            last = g.process(rms: 0.005, frameDuration: frame)
            if last == .resume { break }
        }
        #expect(last == .resume)
        #expect(!g.isProvisional)
    }

    @Test func intermittentSpeechStillCommits() {
        // Natural speech has micro-dips; quiet resets only the retreat clock,
        // voiced time accumulates.
        var g = governor()
        _ = g.process(rms: 0.06, frameDuration: frame)
        var committed = false
        for i in 0..<40 {
            let rms: Float = i % 4 == 3 ? 0.01 : 0.06   // 3 loud, 1 dip
            if g.process(rms: rms, frameDuration: frame) == .commit {
                committed = true
                break
            }
        }
        #expect(committed)
    }

    @Test func resetClearsProvisionalState() {
        var g = governor()
        _ = g.process(rms: 0.06, frameDuration: frame)
        g.reset()
        #expect(!g.isProvisional)
        #expect(g.process(rms: 0.01, frameDuration: frame) == .none)
    }

    @Test func quietBeforeOnsetDoesNothing() {
        var g = governor()
        for _ in 0..<50 {
            #expect(g.process(rms: 0.01, frameDuration: frame) == .none)
        }
        #expect(!g.isProvisional)
    }
}

@Suite struct VADConfigDecodeTests {

    @Test func oldStoreWithoutNewFieldsDecodes() throws {
        // A store persisted before bargeResumeMs/voiceProcessing existed.
        let old = #"{"speechStartRMS":0.02,"speechContinueRMS":0.008,"hangoverMs":900,"minUtteranceMs":300,"preRollMs":300,"bargeInRMSBoost":2.5}"#
        let config = try JSONDecoder().decode(VADConfig.self, from: Data(old.utf8))
        #expect(config.speechStartRMS == 0.02)
        #expect(config.bargeInRMSBoost == 2.5)
        #expect(config.bargeResumeMs == 500)
        #expect(config.voiceProcessing == true)
    }

    @Test func roundTripsWithNewFields() throws {
        var config = VADConfig()
        config.bargeResumeMs = 750
        config.voiceProcessing = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VADConfig.self, from: data)
        #expect(decoded == config)
    }
}

//
//  BargeInGovernorTests.swift
//  MaryVoiceTests
//
//  WHAT: Barge-in onset → pause, commit, retreat.
//  OUT:  BargeInGovernor
//

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

    @Test func resetClearsProvisionalState() {
        var g = governor()
        _ = g.process(rms: 0.06, frameDuration: frame)
        g.reset()
        #expect(!g.isProvisional)
        #expect(g.process(rms: 0.01, frameDuration: frame) == .none)
    }

}


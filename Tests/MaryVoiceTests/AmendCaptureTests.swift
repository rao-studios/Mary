//
//  AmendCaptureTests.swift
//  MaryVoiceTests
//
//  The thinking-phase interrupt's state half: side-buffer capture and the
//  aborted turn's context, driven frame-by-frame through AmendPlanner. This
//  state was previously only reachable indirectly through full-pipeline
//  behavior; extracting it out of VoicePipeline made it directly testable.
//

import AVFoundation
import Foundation
import Testing
@testable import MaryVoice

@Suite struct AmendCaptureTests {

    private static func makeConfig() -> VADConfig {
        var config = VADConfig()
        config.speechStartRMS = 0.1
        config.minUtteranceMs = 100
        config.bargeResumeMs = 100
        return config
    }

    private static func silentBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
    }

    /// Mirrors the switch in `VoicePipeline.handle(frame:)`: the directive is
    /// a pure decision, and the caller is the one that applies it — the same
    /// contract production code drives this type through.
    @discardableResult
    private static func process(
        _ capture: inout AmendCapture, rms: Float, duration: TimeInterval, isTranscribing: Bool
    ) -> AmendPlanner.Directive {
        let directive = capture.directive(rms: rms, frameDuration: duration, isTranscribing: isTranscribing)
        switch directive {
        case .none:
            break
        case .beginCapture:
            capture.beginCapture(preRoll: [], duration: 0)
        case .captureFrame:
            capture.appendFrame(Self.silentBuffer(), duration: duration)
        case .discard:
            capture.clearSideCapture()
        case .deferCommit:
            capture.setPendingCommit()
            capture.appendFrame(Self.silentBuffer(), duration: duration)
        case .commitNow:
            capture.appendFrame(Self.silentBuffer(), duration: duration)
        }
        return directive
    }

    @Test func silenceNeverBeginsCapture() {
        var capture = AmendCapture(vadConfig: Self.makeConfig())
        #expect(Self.process(&capture, rms: 0, duration: 0.02, isTranscribing: false) == .none)
    }

    @Test func onsetBeginsCaptureAndSustainedSpeechCommitsWhileThinking() {
        var capture = AmendCapture(vadConfig: Self.makeConfig())
        #expect(Self.process(&capture, rms: 0.5, duration: 0.02, isTranscribing: false) == .beginCapture)
        // Sustained voiced frames until commitAfter (0.1s) elapses. The
        // governor resets itself on commit (it's one-shot per cycle), so
        // this must catch the transition the moment it happens rather than
        // just inspect whatever the last of a fixed run of frames returns.
        var sawCommit = false
        for _ in 0..<10 where !sawCommit {
            if Self.process(&capture, rms: 0.5, duration: 0.02, isTranscribing: false) == .commitNow {
                sawCommit = true
            }
        }
        #expect(sawCommit)
    }

    @Test func sustainedSpeechDefersWhileTranscribing() {
        var capture = AmendCapture(vadConfig: Self.makeConfig())
        Self.process(&capture, rms: 0.5, duration: 0.02, isTranscribing: true)
        var sawDefer = false
        for _ in 0..<10 where !sawDefer {
            if Self.process(&capture, rms: 0.5, duration: 0.02, isTranscribing: true) == .deferCommit {
                sawDefer = true
            }
        }
        #expect(sawDefer)
        #expect(capture.pendingAmendCommit)
        // Once deferred, `pendingCommit` short-circuits every later frame to
        // `.captureFrame` regardless of what the (still-running) governor
        // computes internally — the correction is captured wholesale.
        #expect(Self.process(&capture, rms: 0, duration: 0.02, isTranscribing: true) == .captureFrame)
    }

    @Test func noiseDiscardsTheCapture() {
        var capture = AmendCapture(vadConfig: Self.makeConfig())
        Self.process(&capture, rms: 0.5, duration: 0.02, isTranscribing: false)
        var sawDiscard = false
        // Quiet frames until retreatAfter (0.1s) elapses.
        for _ in 0..<10 where !sawDiscard {
            if Self.process(&capture, rms: 0, duration: 0.02, isTranscribing: false) == .discard {
                sawDiscard = true
            }
        }
        #expect(sawDiscard)
    }

    @Test func sideBufferCapturesPreRollAndCapsReplay() {
        var capture = AmendCapture(vadConfig: Self.makeConfig())
        let preRoll = [Self.silentBuffer(), Self.silentBuffer()]
        capture.beginCapture(preRoll: preRoll, duration: 0.2)
        #expect(capture.sideBuffer.count == 2)
        // The cap is 10s of appended duration — appending past it must not
        // keep growing the buffer forever.
        for _ in 0..<20 {
            capture.appendFrame(Self.silentBuffer(), duration: 1)
        }
        #expect(capture.sideBuffer.count < 22)
    }

    @Test func resetClearsEverythingIncludingContext() {
        var capture = AmendCapture(vadConfig: Self.makeConfig())
        capture.beginCapture(preRoll: [Self.silentBuffer()], duration: 0.1)
        capture.setPendingCommit()
        capture.amendContext = (original: "hello", wasSubmitted: true)
        capture.reset()
        #expect(capture.sideBuffer.isEmpty)
        #expect(!capture.pendingAmendCommit)
        #expect(capture.amendContext == nil)
    }

    @Test func clearCaptureAndGovernorPreservesContext() {
        var capture = AmendCapture(vadConfig: Self.makeConfig())
        capture.beginCapture(preRoll: [Self.silentBuffer()], duration: 0.1)
        capture.setPendingCommit()
        capture.amendContext = (original: "hello", wasSubmitted: true)
        capture.clearCaptureAndGovernor()
        #expect(capture.sideBuffer.isEmpty)
        #expect(!capture.pendingAmendCommit)
        #expect(capture.amendContext?.original == "hello")
    }
}

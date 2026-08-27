//
//  AmendCapture.swift
//  MaryVoice
//
//  State for the thinking-phase interrupt (the amend flow): what correction
//  audio is being captured, and the aborted turn's context. AmendPlanner is
//  already the pure decision half of this pair ("what does the pipeline do
//  about this frame, given where the turn is"); this is the missing state
//  half it decides over.
//

import AVFoundation
import Foundation

struct AmendCapture {
    private var thinkGovernor: BargeInGovernor?
    private(set) var sideBuffer: [AVAudioPCMBuffer] = []
    private var sideBufferDuration: TimeInterval = 0
    private var sideCapturing = false
    /// Commit landed while the ORIGINAL transcript was still resolving —
    /// `runTurn` hands over to amend capture right after `finish()` returns.
    private(set) var pendingAmendCommit = false

    /// Set while a correction is being captured: the aborted turn's query
    /// text + whether it ever reached the responder.
    var amendContext: (original: String, wasSubmitted: Bool)?

    private static let sideBufferMaxSeconds: TimeInterval = 10

    private let vadConfig: VADConfig

    init(vadConfig: VADConfig) {
        self.vadConfig = vadConfig
    }

    /// Speech detector while the turn is transcribing/thinking — unboosted
    /// (no audio out, no echo) and destructive only at commit. Lazily builds
    /// its governor on first use, same as the inline block this replaced.
    mutating func directive(
        rms: Float,
        frameDuration: TimeInterval,
        isTranscribing: Bool
    ) -> AmendPlanner.Directive {
        if thinkGovernor == nil {
            thinkGovernor = BargeInGovernor(
                onsetRMS: vadConfig.speechStartRMS,   // no boost — no audio out
                commitAfter: Double(vadConfig.minUtteranceMs) / 1000,
                retreatAfter: Double(vadConfig.bargeResumeMs) / 1000)
        }
        let action = thinkGovernor!.process(rms: rms, frameDuration: frameDuration)
        return AmendPlanner.directive(
            for: action,
            capturing: sideCapturing,
            isTranscribing: isTranscribing,
            pendingCommit: pendingAmendCommit)
    }

    mutating func setPendingCommit() {
        pendingAmendCommit = true
    }

    /// Snapshot the pre-roll (it holds the onset syllables) and start
    /// buffering — silently; the turn keeps generating.
    mutating func beginCapture(preRoll: [AVAudioPCMBuffer], duration: TimeInterval) {
        sideCapturing = true
        sideBuffer = preRoll
        sideBufferDuration = duration
    }

    /// Keep-first under the cap: the correction's START matters most, and a
    /// bounded buffer bounds the replay latency at hand-off.
    mutating func appendFrame(_ buffer: AVAudioPCMBuffer, duration: TimeInterval) {
        guard sideBufferDuration < Self.sideBufferMaxSeconds else { return }
        sideBuffer.append(buffer)
        sideBufferDuration += duration
    }

    mutating func clearSideCapture() {
        sideCapturing = false
        sideBuffer = []
        sideBufferDuration = 0
    }

    mutating func reset() {
        clearSideCapture()
        thinkGovernor = nil
        pendingAmendCommit = false
        amendContext = nil
    }

    /// Everything `reset()` does EXCEPT clearing `amendContext` — used right
    /// after a correction utterance opens, when the context it just captured
    /// must survive (the eventual `submitTurn(correction:)` still needs it).
    mutating func clearCaptureAndGovernor() {
        clearSideCapture()
        thinkGovernor = nil
        pendingAmendCommit = false
    }

    /// The auto-re-arm at the end of a turn only ever demoted the governor by
    /// itself — the side buffer and `amendContext` are unrelated to a normal
    /// turn's completion and must survive it untouched.
    mutating func resetGovernor() {
        thinkGovernor = nil
    }
}

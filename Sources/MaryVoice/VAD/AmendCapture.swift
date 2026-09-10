//
//  AmendCapture.swift
//  MaryVoice
//
//  WHAT: State half of the thinking-phase interrupt (correction audio + context).
//  IN:   VoicePipeline+FrameHandling / AmendPlanner
//  OUT:  sideBuffer → beginAmendCapture; amendContext → submitTurn(correction:)
//
//  Sibling of AmendPlanner.swift (pure decisions).
//

import AVFoundation
import Foundation

struct AmendCapture {
    private var thinkGovernor: BargeInGovernor?
    private(set) var sideBuffer: [AVAudioPCMBuffer] = []
    private var sideBufferDuration: TimeInterval = 0
    private var sideCapturing = false
    /// Commit landed while the original transcript was still resolving.
    private(set) var pendingAmendCommit = false

    /// Aborted turn's query + whether it reached the responder.
    var amendContext: (original: String, wasSubmitted: Bool)?

    private static let sideBufferMaxSeconds: TimeInterval = 10

    private let vadConfig: VADConfig

    init(vadConfig: VADConfig) {
        self.vadConfig = vadConfig
    }

    /// Speech detector while transcribing/thinking — unboosted, destructive only at commit.
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

    /// Snapshot pre-roll and start buffering; the turn keeps generating.
    mutating func beginCapture(preRoll: [AVAudioPCMBuffer], duration: TimeInterval) {
        sideCapturing = true
        sideBuffer = preRoll
        sideBufferDuration = duration
    }

    /// Keep-first under the cap — correction start matters most.
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

    /// Reset without clearing `amendContext` — correction utterance just opened.
    mutating func clearCaptureAndGovernor() {
        clearSideCapture()
        thinkGovernor = nil
        pendingAmendCommit = false
    }

    /// Auto re-arm at turn end only demotes the governor.
    mutating func resetGovernor() {
        thinkGovernor = nil
    }
}

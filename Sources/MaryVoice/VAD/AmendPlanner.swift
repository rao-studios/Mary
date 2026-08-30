//
//  AmendPlanner.swift
//  MaryVoice
//
//  WHAT: Decision table for the thinking-phase interrupt (amend flow).
//  IN:   BargeInGovernor.Action + capture flags
//  OUT:  beginCapture | captureFrame | commitNow | deferCommit | discard
//
//  PIN: capture-first, cancel-late. Commit during .transcribing defers until
//       finish() returns the original text.
//

enum AmendPlanner {

    enum Directive: Equatable {
        case none
        /// Onset: snapshot pre-roll and start buffering silently.
        case beginCapture
        /// Provisional/committed speech continues — keep buffering.
        case captureFrame
        /// Sustained speech in .thinking — supersede now.
        case commitNow
        /// Sustained speech in .transcribing — flag; runTurn hands over after finish().
        case deferCommit
        /// Noise — drop the capture, turn untouched.
        case discard
    }

    static func directive(
        for action: BargeInGovernor.Action,
        capturing: Bool,
        isTranscribing: Bool,
        pendingCommit: Bool
    ) -> Directive {
        // Once committed-but-deferred, every frame is part of the correction.
        if pendingCommit { return .captureFrame }
        switch action {
        case .none:
            return capturing ? .captureFrame : .none
        case .pause:
            return .beginCapture
        case .commit:
            return isTranscribing ? .deferCommit : .commitNow
        case .resume:
            return capturing ? .discard : .none
        }
    }
}

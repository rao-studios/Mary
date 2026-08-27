//
//  AmendPlanner.swift
//  MaryVoice
//
//  Pure decision table for the thinking-phase interrupt (the amend flow).
//  The BargeInGovernor decides WHEN speech is real; this decides WHAT the
//  pipeline does about it, given where the turn is:
//
//  - capture-first, cancel-late: onset starts a silent side-capture only;
//    the in-flight turn is disturbed ONLY at commit (≥ minUtteranceMs voiced).
//  - a retreat (noise) discards the capture and leaves the turn untouched.
//  - commit during .transcribing defers — the shared transcriber is mid-
//    finish() resolving the ORIGINAL text; the amend takes over right after.
//

enum AmendPlanner {

    enum Directive: Equatable {
        /// Nothing to do this frame.
        case none
        /// Onset: snapshot the pre-roll and start buffering frames silently.
        case beginCapture
        /// Provisional/committed speech continues — keep buffering.
        case captureFrame
        /// Sustained speech in .thinking — supersede the turn now.
        case commitNow
        /// Sustained speech in .transcribing — flag it; runTurn hands over
        /// right after the original transcript resolves.
        case deferCommit
        /// It was just noise — drop the capture, turn untouched.
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

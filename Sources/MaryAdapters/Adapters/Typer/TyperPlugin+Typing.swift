//
//  TyperPlugin+Typing.swift
//

import AppKit
import Foundation
import os

extension TyperPlugin {

    /// The one typing path both Skill bindings share: guards → stage lease + focus
    /// suppression bracket → type → honest outcome. Pause and focus-loss are
    /// RESUMABLE (remainder + target saved); "stop" is final.
    static func performTyping(
        _ text: String,
        target: TypingSurface,
        mode: TypingMode = .compose,
        explicitTarget: Bool = true
    ) async -> SkillOutcome {
        guard SelectionSurfacePolicy.permitsProseApplication(target.bundleID) else {
            return SkillOutcome(
                ok: false,
                summary: "I don't type prose into code, terminals, or my own request surface.")
        }
        // Code is never typed — but the gate is TARGET-AWARE now (2026-08-11):
        // "type this in TextEdit" while Xcode happens to be frontmost used to
        // refuse outright, thirty lines above the activation that would have
        // brought TextEdit forward. An EXPLICIT (named/staged/saved) target
        // proceeds — the policy gate above refuses code targets and the
        // bring-forward below verifies the displacement; only an IMPLICIT
        // resolution while the user sits in Xcode still refuses, which is the
        // focus-steal this sentence was always about.
        // NO SECOND CODE GUARD. Bonnie refused here when Xcode was frontmost
        // and the target was implicit. `SelectionSurfacePolicy` already
        // refuses code editors and terminals as prose surfaces by bundle id,
        // and the resolution ladder consults it on every rung — so this was
        // one rule spelled twice, with only the second spelling naming an
        // application.
        if let block = AppAutomationGate.accessibilityBlock() {
            return SkillOutcome(ok: false, summary: block)
        }
        guard target.isRunning else {
            return SkillOutcome(
                ok: false,
                summary: "Open \(target.spokenName) first — I type at your cursor, so the document needs to be in front of you.")
        }
        // Stage lease FIRST, atomically: `acquire` preempts the current
        // holder and never overwrites one that failed to release — the caller
        // either owns the stage or drives no focus and no synthetic input.
        // (The legacy preemptForNewClaim + claim pair could race the app's own
        // window creation between the two calls.) The lease's pause flag is
        // checked by the typing loop every chunk.
        let pauseFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
        guard let lease = await StageArbiter.shared.acquire(owner: "typing", onPreempt: {
            pauseFlag.withLock { $0 = true }
        }) else {
            return SkillOutcome(
                ok: false,
                summary: "Another action is still holding the stage — ask me again in a moment.")
        }
        let hold = WorkspaceFocusTracker.shared.beginSelfDriving()
        // The defer is the backstop (endSelfDriving is idempotent); the
        // pause/lostFocus branches below end the hold EXPLICITLY with no
        // tail — there the USER moved (or another action takes the stage),
        // and a tail would swallow their genuine new focus signal.
        defer {
            StageArbiter.shared.release(lease)
            WorkspaceFocusTracker.shared.endSelfDriving(hold)
        }
        // Two-road verified activation (VerifiedActivation): cooperative
        // activation can refuse silently from a background caller, and the
        // Apple Events road is the door it cannot refuse the same way.
        // `requireVisibleWindow`: frontmost is not visible. An app whose
        // windows are all minimized takes the foreground with nothing to type
        // into, and every keystroke below would go nowhere while reporting
        // success. `raise`/`raiseAll` restore windows themselves; the typer
        // has to ask.
        let raised = await VerifiedActivation.bringForward(
            bundleID: target.bundleID,
            matchPrefix: target.matchPrefix,
            requireVisibleWindow: true)
        if let refusal = raised.reason(app: target.spokenName) {
            return SkillOutcome(ok: false, summary: refusal)
        }
        // A running non-code app is not automatically an ordinary writing
        // surface: it may have a toolbar, button, or empty window focused.
        // Verify a focused AX text capability before sending keystrokes
        // anywhere — a caret, selected text, or a nonempty unreadable range
        // all prove a live surface; `.unavailable` does not. The check RETRIES
        // over a short settle window: a freshly created document (Pages'
        // `make new document`) takes a beat to hand first-responder to its
        // body, and the old single-shot check ran at the least-settled moment.
        guard await awaitFocusedTextSurface(in: target) else {
            return SkillOutcome(
                ok: false,
                summary: "I couldn't find a text cursor in \(target.spokenName) after waiting for it. Click into the document body — or open one first with its create Skill — then call type_at_cursor again.")
        }
        // WHAT THE KEYSTROKES ARE ABOUT TO LAND IN, read once, here.
        //
        // BEFORE THE TYPING AND NOT AFTER, which matters for exactly one
        // branch: `.lostFocus` means the user moved away mid-passage, so a
        // read taken afterwards would name whatever they moved TO and file it
        // as the thing Mary typed into. Read at the moment the surface is
        // verified, this names the surface that was verified.
        //
        // The check above proves a writable text surface exists but only ever
        // returned a Bool — the discard `SkillOutcome.target`'s own comment
        // names. This is the second read that closes it.
        let acted = focusedRecord(in: target)
        if mode == .replaceSelection {
            guard hasFrontmostSelection(in: target) else {
                return SkillOutcome(
                    ok: false,
                    summary: "Select the words you want changed first, then ask me again.")
            }
            guard !isInternalSelectionInstruction(text) else {
                return SkillOutcome(
                    ok: false,
                    summary: "I refused to replace the selected text with an internal instruction.")
            }
        }

        let result = await KeyboardTyper.type(
            text,
            targetPrefix: target.matchPrefix,
            shouldPause: { pauseFlag.withLock { $0 } })

        // The normalized text is what `typedCharacters` indexes into.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        switch result {
        // Typing is the one path where Mary's hands change the prose the
        // user is looking at, so its deposit is a statement about the
        // document AS IT NOW STANDS — including the passage itself, which
        // rides in via the turn's `userText`. `.stateSnapshot` keys it by
        // document identity so the next passage typed into the same document
        // REPLACES this one. Without that, a paragraph dictated, then
        // rewritten, then deleted stays independently retrievable forever —
        // which is precisely how a deleted paragraph got narrated back.
        case .completed:
            // The staged-surface hint was delivered — it must not steer a
            // later unrelated write.
            StagedWritingSurface.shared.consume(bundleID: target.bundleID)
            let words = text.split(whereSeparator: \.isWhitespace).count
            let verb = mode == .replaceSelection ? "Replaced the selected text" : "Typed it"
            return SkillOutcome(
                ok: true,
                summary: "\(verb) — \(SpokenPhrase.countWord(words)) word\(words == 1 ? "" : "s"). Command Z takes it back.",
                archivePolicy: .stateSnapshot,
                typingDisposition: .completed,
                target: acted)
        case .stopped(let typed):
            // Stop is final — never leave a remainder a later "continue"
            // would surprise-type.
            TypingSession.shared.clear()
            return SkillOutcome(
                ok: true,
                summary: "Stopped — I'd typed \(KeyboardTyper.wordsPhrase(of: normalized, typedCharacters: typed)).",
                archivePolicy: .stateSnapshot,
                target: acted)
        case .paused(let typed):
            WorkspaceFocusTracker.shared.endSelfDriving(hold, tail: 0)
            TypingSession.shared.save(
                remainder: String(normalized.dropFirst(typed)), target: target)
            return SkillOutcome(
                ok: true,
                summary: "I paused the typing — \(KeyboardTyper.wordsPhrase(of: normalized, typedCharacters: typed)) in. Say continue when you're ready and I'll pick up right there.",
                archivePolicy: .stateSnapshot,
                typingDisposition: .partialResumable,
                target: acted)
        case .lostFocus(let typed, _):
            WorkspaceFocusTracker.shared.endSelfDriving(hold, tail: 0)
            TypingSession.shared.save(
                remainder: String(normalized.dropFirst(typed)), target: target)
            return SkillOutcome(
                ok: true,
                summary: "I paused — \(target.spokenName) lost focus after \(KeyboardTyper.wordsPhrase(of: normalized, typedCharacters: typed)). Click back into the document and say continue.",
                archivePolicy: .stateSnapshot,
                typingDisposition: .partialResumable,
                target: acted)
        }
    }

    /// The frontmost application's focused element, as a record — nil when
    /// the family that was verified is no longer the one in front.
    private static func focusedRecord(in target: TypingSurface) -> AXElementRecord? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID.hasPrefix(target.matchPrefix)
        else { return nil }
        return ActedElementReader.focusedElement(pid: front.processIdentifier)
    }

    private static func hasFrontmostSelection(in target: TypingSurface) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID.hasPrefix(target.matchPrefix)
        else { return false }
        let sample = AXSelectionReader.focusedSelectionSample(pid: front.processIdentifier)
        guard isWritableTextSurface(sample, applicationID: bundleID) else {
            return false
        }
        return selectionMatches(
            sample,
            targetApplicationID: target.bundleID,
            expectedHandoff: AmbientContextStore.shared.routedSelectionHandoff(
                requiringWritingTarget: true))
    }

    /// The pre-type capability check, retried over a bounded settle window.
    /// A freshly created document (Pages' `make new document`, a new TextEdit
    /// note) takes a beat to hand first-responder to its body; a single-shot
    /// check at activation time reads the least-settled moment and refuses a
    /// document that is perfectly typeable 400ms later.
    static func awaitFocusedTextSurface(
        in target: TypingSurface,
        deadline: TimeInterval = 2.0
    ) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while true {
            if hasFocusedTextSurface(in: target) { return true }
            guard Date() < end, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func hasFocusedTextSurface(in target: TypingSurface) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID.hasPrefix(target.matchPrefix)
        else { return false }
        // The typing-gate sample descends when focus names a canvas/container
        // (Pages' fresh document) — the strict focused-only sample stays the
        // authority for selection REPLACEMENT, which needs exact focus.
        return isWritableTextSurface(
            AXSelectionReader.focusedWritableSurfaceSample(pid: front.processIdentifier),
            applicationID: bundleID)
    }

    /// Pure state rule for the pre-type capability check. An unreadable
    /// nonempty range still proves the focused element is a text surface; it
    /// is only insufficient evidence for replacing a particular selection.
    static func isTextSurface(_ sample: AXSelectionReader.FocusedSelectionSample) -> Bool {
        switch sample.state {
        case .selected, .caret, .unreadableNonemptyRange: return true
        case .ambiguousSelection, .unavailable: return false
        }
    }

    /// A readable text surface is not automatically a write target.  We only
    /// synthesize keys when the exact focused source reports editable, or a
    /// known prose representation explicitly upgrades a canvas that omits
    /// AXEditable. This check happens again after the app is frontmost.
    static func isWritableTextSurface(
        _ sample: AXSelectionReader.FocusedSelectionSample,
        applicationID: String
    ) -> Bool {
        isTextSurface(sample)
            && SelectionSurfacePolicy.isWritableProseSurface(
                applicationID: applicationID,
                editability: sample.editability)
    }

    /// `replace_selection` verifies the same source primitive that created a
    /// turn's highlight. The legacy bounded tree reader could find a title or
    /// control under Pages and approve a replacement on the wrong surface.
    /// If the turn has a canonical selection, the live surface must still
    /// name that exact app, process, text, and (when AX supplies it) surface.
    static func selectionMatches(
        _ sample: AXSelectionReader.FocusedSelectionSample,
        targetApplicationID: String,
        expectedHandoff: AmbientSelectionHandoff?
    ) -> Bool {
        guard case .selected(let reading) = sample.state,
              !reading.text.isEmpty,
              reading.completeness == .complete
        else { return false }
        guard let expectedHandoff else { return true }
        guard expectedHandoff.applicationID == targetApplicationID,
              expectedHandoff.processID == Int32(sample.processID),
              expectedHandoff.text == reading.text,
              expectedHandoff.completeness == .complete,
              expectedHandoff.editability != .readOnly
        else { return false }
        if let expectedDigest = expectedHandoff.valueDigest,
           let liveDigest = reading.valueDigest,
           expectedDigest != liveDigest {
            return false
        }
        if let expectedSurface = expectedHandoff.sourceSurfaceID,
           let liveSurface = sample.sourceSurfaceID,
           expectedSurface != liveSurface {
            return false
        }
        if let expectedRange = expectedHandoff.range,
           let liveRange = reading.range,
           expectedRange != liveRange {
            return false
        }
        return true
    }

    static func isInternalSelectionInstruction(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let markers = [
            "revision note:", "continuation note:", "executor contract",
            "type_at_cursor", "replace_selection", "selected-text revision",
        ]
        return markers.contains { normalized.contains($0) }
    }

}

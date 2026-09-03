//
//  TyperPlugin+Typing.swift
//  MaryPlugin
//
//  WHAT: Shared typing path for type_at_cursor and resume_typing.
//  IN:   TyperPlugin+SkillBindings / KeyboardTyper / StageArbiter
//  OUT:  TypingSession / SkillOutcome
//  PIN:  Sibling of TyperPlugin.swift. Pause/lostFocus resumable; "stop" is final.
//

import AppKit
import Foundation
import MaryComputerUse
import os

extension TyperPlugin {

    /// Shared typing path: guards → stage lease → type → honest outcome.
    /// PIN: pause/lostFocus save remainder; "stop" is final.
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
        // PIN: code gate is target-aware. Explicit named/staged target proceeds;
        // implicit while sitting in a code editor still refuses. SelectionSurfacePolicy
        // already refuses code/terminal by bundle id — no second named-app guard.
        if let block = AppAutomationGate.accessibilityBlock() {
            return SkillOutcome(ok: false, summary: block)
        }
        guard target.isRunning else {
            return SkillOutcome(
                ok: false,
                summary: "Open \(target.spokenName) first — I type at your cursor, so the document needs to be in front of you.")
        }
        // Stage lease first, atomically. Typing loop checks the pause flag each chunk.
        let pauseFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
        guard let lease = await StageArbiter.shared.acquire(owner: "typing", onPreempt: {
            pauseFlag.withLock { $0 = true }
        }) else {
            return SkillOutcome(
                ok: false,
                summary: "Another action is still holding the stage — ask me again in a moment.")
        }
        let hold = WorkspaceFocusTracker.shared.beginSelfDriving()
        // Defer is the backstop. Pause/lostFocus end the hold explicitly (user moved).
        defer {
            StageArbiter.shared.release(lease)
            WorkspaceFocusTracker.shared.endSelfDriving(hold)
        }
        // VerifiedActivation, requireVisibleWindow: frontmost is not typeable if all windows are minimized.
        let raised = await VerifiedActivation.bringForward(
            bundleID: target.bundleID,
            matchPrefix: target.matchPrefix,
            requireVisibleWindow: true)
        if let refusal = raised.reason(app: target.spokenName) {
            return SkillOutcome(ok: false, summary: refusal)
        }
        // Focused AX text capability, retried over a settle window (fresh documents lag).
        guard await awaitFocusedTextSurface(in: target) else {
            return SkillOutcome(
                ok: false,
                summary: "I couldn't find a text cursor in \(target.spokenName) after waiting for it. Click into the document body — or open one first with its create Skill — then call type_at_cursor again.")
        }
        // Record the surface before typing — `.lostFocus` would otherwise name where the user went.
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

        // typedCharacters indexes into the normalized text.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        switch result {
        // `.stateSnapshot` so the next passage into the same document replaces this one.
        case .completed:
            // Staged-surface hint delivered — must not steer a later unrelated write.
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
            // Stop is final — never leave a remainder for a later "continue".
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

    /// Frontmost focused element, or nil if the verified family is no longer in front.
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

    /// Pre-type capability check, retried over a settle window (fresh documents lag).
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
        // Typing-gate sample may descend into a canvas. Replacement still needs exact focus.
        return isWritableTextSurface(
            AXSelectionReader.focusedWritableSurfaceSample(pid: front.processIdentifier),
            applicationID: bundleID)
    }

    /// Unreadable nonempty range still proves a text surface; not enough for replace.
    static func isTextSurface(_ sample: AXSelectionReader.FocusedSelectionSample) -> Bool {
        switch sample.state {
        case .selected, .caret, .unreadableNonemptyRange: return true
        case .ambiguousSelection, .unavailable: return false
        }
    }

    /// Keys only when focused source reports editable, or a known prose canvas upgrades AXEditable.
    static func isWritableTextSurface(
        _ sample: AXSelectionReader.FocusedSelectionSample,
        applicationID: String
    ) -> Bool {
        isTextSurface(sample)
            && SelectionSurfacePolicy.isWritableProseSurface(
                applicationID: applicationID,
                editability: sample.editability)
    }

    /// replace_selection must still name the same app, process, text, and surface as the highlight.
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

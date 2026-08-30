//
//  DictationRunner.swift
//  MaryAdapter
//
//  THE TYPER'S ANSWER TO THE KIT'S DICTATION VERBS.
//
//  `DictationSession`, at the contract root, holds the caret and declares
//  open, type and scratch. This installs them. The split is the
//  `PausedTypingSession` idiom: `MaryBrain` owns the turn loop where a held
//  session short-circuits and drives it through the contract alone, so a
//  process with no typer installed still answers every verb coherently.
//
//  ONE VERIFICATION, AT THE OPEN. Everything a `type_at_cursor` run proves
//  before its first keystroke is proved once here: a resolved target, a prose
//  surface, Accessibility, verified activation with a visible window, and a
//  live focused text element. What the session pins is the result of that
//  proof, so the sentences that follow do not re-litigate it.
//
//  AND THE OPEN IS THE ONLY MOMENT DICTATION MAY MOVE FOCUS. See `typeSpan`.
//

import AppKit
import Foundation
import os

enum DictationRunner {

    static let installHooks: Void = {
        DictationSession.installOpen { app in await open(app: app) }
        DictationSession.installType { text in await typeSpan(text) }
        DictationSession.installScratch { await scratch() }
    }()

    // MARK: - Opening

    static func open(app: String?) async -> DictationSession.OpenResult {
        guard let target = TypingSurface.resolve(
            requested: app,
            preferredApplicationID: nil)
        else {
            return .refused(
                "I couldn't tell where to write. Click into the document you want, then say take this down.")
        }
        guard TypingSurface.canReceiveProse(bundleID: target.bundleID) else {
            // Browsers are deliberately outside the CGEvent prose path, so a
            // Google Docs tab is not a v1 dictation surface. Say which, rather
            // than failing vaguely — the user can move to a real editor.
            return .refused(
                "I can't dictate into \(target.spokenName). Open the document in a writing app and say take this down there.")
        }
        if let block = AppAutomationGate.accessibilityBlock() {
            return .refused(block)
        }
        guard target.isRunning else {
            return .refused(
                "Open \(target.spokenName) first — I write at your cursor, so the document needs to be in front of you.")
        }
        let raised = await VerifiedActivation.bringForward(
            bundleID: target.bundleID,
            matchPrefix: target.matchPrefix,
            requireVisibleWindow: true)
        if let refusal = raised.reason(app: target.spokenName) {
            return .refused(refusal)
        }
        guard await TyperPlugin.awaitFocusedTextSurface(in: target) else {
            return .refused(
                "I couldn't find a text cursor in \(target.spokenName). Click into the document body, then say take this down again.")
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier?.hasPrefix(target.matchPrefix) == true
        else {
            return .refused("\(target.spokenName) didn't come to the foreground.")
        }
        let sample = AXSelectionReader.focusedWritableSurfaceSample(
            pid: front.processIdentifier)
        // A PAUSED PASSAGE MUST NOT SURVIVE INTO A SESSION. Newest wins, the
        // same rule `type_at_cursor` applies — otherwise a later "continue"
        // would surprise-type a remainder into the middle of a scene.
        TypingSession.shared.clear()
        let held = DictationSession.Held(
            bundleID: target.bundleID,
            matchPrefix: target.matchPrefix,
            spokenName: target.spokenName,
            placeName: focusedWindowTitle(pid: front.processIdentifier),
            processID: front.processIdentifier,
            surfaceID: sample.sourceSurfaceID)
        DictationSession.shared.open(held)
        return .opened(held)
    }

    // MARK: - Typing a span

    /// EVERY LATER UTTERANCE, and the contract differs from `performTyping` in
    /// exactly one way that matters: **this never activates.**
    ///
    /// `type_at_cursor` brings its target forward, which is right for a
    /// one-shot instruction. A held session must not: the user who alt-tabs to
    /// Mail mid-scene has stopped dictating, and dragging Scrivener back to
    /// spray a paragraph into it is the worst thing this feature could do. So
    /// the pinned target must ALREADY own the foreground, and the pinned text
    /// element must still be the focused one — a different document in the same
    /// app is a different caret.
    ///
    /// If anyone later "fixes" a flaky test by adding a `bringForward` here,
    /// that is the bug returning. `DictationSessionTests` asserts the absence.
    static func typeSpan(_ text: String) async -> DictationSession.SpanResult {
        guard let held = DictationSession.shared.held() else { return .unavailable }
        guard AppAutomationGate.accessibilityBlock() == nil else {
            DictationSession.shared.close()
            return .lostSurface("I've lost Accessibility access, so I stopped dictating.")
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier?.hasPrefix(held.matchPrefix) == true,
              front.processIdentifier == held.processID
        else {
            DictationSession.shared.close()
            return .lostSurface(
                "I stopped — \(held.spokenName) isn't in front any more. \(spokenCount(held)) in.")
        }
        let sample = AXSelectionReader.focusedWritableSurfaceSample(pid: held.processID)
        guard sample.sourceSurfaceID == held.surfaceID else {
            DictationSession.shared.close()
            return .lostSurface(
                "I stopped — the cursor moved to a different document. \(spokenCount(held)) in.")
        }
        let span = joined(text, after: held)
        let lease = await StageArbiter.shared.acquire(owner: "dictation", onPreempt: {})
        guard let lease else { return .unavailable }
        let hold = WorkspaceFocusTracker.shared.beginSelfDriving()
        defer {
            StageArbiter.shared.release(lease)
            WorkspaceFocusTracker.shared.endSelfDriving(hold)
        }
        let result = await KeyboardTyper.type(span, targetPrefix: held.matchPrefix)
        switch result {
        case .completed:
            let words = span.split(whereSeparator: \.isWhitespace).count
            DictationSession.shared.noteSpan(words: words, characters: span.count)
            return .typed(words: words)
        case .lostFocus, .paused, .stopped:
            DictationSession.shared.close()
            return .lostSurface(
                "I stopped mid-sentence — \(held.spokenName) lost focus. \(spokenCount(held)) in.")
        }
    }

    // MARK: - Scratch

    static func scratch() async -> DictationSession.SpanResult {
        guard let held = DictationSession.shared.held() else { return .unavailable }
        guard held.lastSpanCharacters > 0 else { return .typed(words: 0) }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier?.hasPrefix(held.matchPrefix) == true,
              front.processIdentifier == held.processID
        else {
            DictationSession.shared.close()
            return .lostSurface(
                "I couldn't scratch that — \(held.spokenName) isn't in front any more.")
        }
        let lease = await StageArbiter.shared.acquire(owner: "dictation", onPreempt: {})
        guard let lease else { return .unavailable }
        let hold = WorkspaceFocusTracker.shared.beginSelfDriving()
        defer {
            StageArbiter.shared.release(lease)
            WorkspaceFocusTracker.shared.endSelfDriving(hold)
        }
        let removed = held.lastSpanCharacters
        let result = await KeyboardTyper.delete(
            count: removed, targetPrefix: held.matchPrefix)
        switch result {
        case .completed:
            DictationSession.shared.clearLastSpan()
            return .typed(words: 0)
        case .lostFocus, .paused, .stopped:
            DictationSession.shared.close()
            return .lostSurface("I couldn't finish scratching that — the document lost focus.")
        }
    }

    // MARK: - Shaping

    /// Consecutive utterances are one paragraph, not one word. Without this,
    /// "she waited" then "and listened" arrives as "she waitedand listened".
    /// A span that already begins with whitespace or a newline is left alone —
    /// that is the structural controls' doing.
    static func joined(_ text: String, after held: DictationSession.Held) -> String {
        guard held.wordsTyped > 0 else { return text }
        guard let first = text.first else { return text }
        if first.isNewline || first.isWhitespace { return text }
        return " " + text
    }

    private static func spokenCount(_ held: DictationSession.Held) -> String {
        SpokenPhrase.countWord(held.wordsTyped) + (held.wordsTyped == 1 ? " word" : " words")
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = AX.element(app, kAXFocusedWindowAttribute),
              let text = AX.string(window, kAXTitleAttribute),
              !text.isEmpty
        else { return nil }
        return text
    }
}

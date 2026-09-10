//
//  DictationRunner.swift
//  MaryPlugin
//
//  WHAT: Install DictationSession open / type / scratch for the typer.
//  IN:   DictationSession (kit) / TyperPlugin
//  OUT:  KeyboardTyper / TypingSession
//  PIN:  Verify once at open. Open is the only moment dictation may move focus.
//

import AppKit
import Foundation
import MaryComputerUse
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
            // Browsers are outside the CGEvent prose path.
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
        // A paused passage must not survive into a session — newest wins.
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

    /// Later utterances. PIN: never activates — pinned target must already own focus.
    /// DictationSessionTests asserts the absence of bringForward.
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

    /// Join consecutive utterances with a space unless the span already leads with whitespace.
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

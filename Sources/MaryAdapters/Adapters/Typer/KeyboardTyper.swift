//
//  KeyboardTyper.swift
//  MaryBrain
//
//  The live typer: posts generated prose as SYNTHETIC KEYBOARD EVENTS at the
//  user's text cursor — no app automation, no clipboard theft. Text lands in
//  the target app's own undo stack (Cmd-Z just works), and because it is
//  real typing it works in any app that takes keystrokes; Scrivener is the
//  first target, Notes/Reminders later.
//
//  Two invariants make it safe and assistive-grade:
//  1. CGEvents land in whatever app is FRONTMOST at post time — so the
//     intended target is verified between EVERY chunk; any focus change
//     halts typing instantly (this is also the "never type into Xcode"
//     guarantee, enforced at the binding layer before the first key).
//  2. The loop checks cancellation between chunks — a spoken "stop" cancels
//     the surrounding routine task and typing halts within one chunk.
//
//  Newlines are posted as real Return keypresses (key code 36): a typed
//  "\n" via the unicode path is unreliable across apps.
//

import AppKit
import CoreGraphics
import Foundation

/// One typed unit: a short run of characters posted as a single unicode key
/// event, or a Return keypress.
enum TypeToken: Equatable, Sendable {
    case text(String)
    case newline
    /// N backspaces. `PagesPassageWriter` asked for this in writing —
    /// "`TypeToken` has two cases … so `KeyboardTyper` has no way to express a
    /// Delete at all. The honest fix is a third token case, which belongs to
    /// that file and its owner." Dictation's "scratch that" is the owner
    /// arriving: it removes the span just typed, and it must go through THIS
    /// loop rather than posting its own events, because the per-token
    /// frontmost check is the only thing standing between a backspace and
    /// whatever application the user switched to mid-sentence.
    case delete(count: Int)
}

/// Seam for tests: the CGEvent poster is the only non-deterministic part.
protocol KeyEventPosting: Sendable {
    func post(_ token: TypeToken)
}

/// The real thing — HID-level unicode typing + Return keycodes.
struct CGKeyEventPoster: KeyEventPosting {
    func post(_ token: TypeToken) {
        switch token {
        case .delete(let count):
            // kVK_Delete = 51 (backspace).
            for _ in 0..<max(0, count) {
                CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true)?
                    .post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false)?
                    .post(tap: .cghidEventTap)
            }
        case .newline:
            // kVK_Return = 36.
            CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true)?
                .post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)?
                .post(tap: .cghidEventTap)
        case .text(let run):
            var units = Array(run.utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?
                .post(tap: .cghidEventTap)
        }
    }
}

public enum KeyboardTyper {

    /// UTF-16 units per unicode key event — small chunks are the reliable
    /// cross-app envelope, and they bound how much lands after a "stop".
    static let chunkLimit = 16

    /// How the typing run ended. `typedCharacters` counts grapheme clusters
    /// actually posted (newlines count as one) so callers can report honest
    /// partial progress.
    enum TypeResult: Equatable, Sendable {
        case completed(typedCharacters: Int)
        /// Cooperative cancellation — the user said "stop". Remainder dropped.
        case stopped(typedCharacters: Int)
        /// The target app lost frontmost mid-typing; typing halted instantly.
        /// Resumable: the caller saves the remainder.
        case lostFocus(typedCharacters: Int, frontmost: String?)
        /// A stage preemption asked typing to step aside (another stage
        /// action is about to run). Resumable, like lostFocus.
        case paused(typedCharacters: Int)
    }

    /// Split prose into postable tokens: newline tokens plus text runs that
    /// never split a grapheme cluster and stay ≤ chunkLimit UTF-16 units.
    /// "\r\n" and "\r" normalize to one newline.
    static func tokens(for text: String) -> [TypeToken] {
        var result: [TypeToken] = []
        var run = ""
        var runUnits = 0
        func flush() {
            if !run.isEmpty { result.append(.text(run)); run = ""; runUnits = 0 }
        }
        for character in text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n") {
            if character == "\n" {
                flush()
                result.append(.newline)
                continue
            }
            let width = character.utf16.count
            if runUnits + width > chunkLimit { flush() }
            run.append(character)
            runUnits += width
        }
        flush()
        return result
    }

    /// Type `text` at the cursor of the app matching `targetPrefix`,
    /// verifying focus and cancellation between every token. Call this
    /// INLINE from a binding closure (never a detached Task) so the routine
    /// machinery's bare-"stop" cancellation reaches the loop.
    static func type(
        _ text: String,
        targetPrefix: String,
        poster: KeyEventPosting = CGKeyEventPoster(),
        frontmost: @Sendable () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        shouldPause: @Sendable () -> Bool = { false },
        interChunkNanoseconds: UInt64 = 25_000_000
    ) async -> TypeResult {
        var typed = 0
        for token in tokens(for: text) {
            if Task.isCancelled { return .stopped(typedCharacters: typed) }
            if shouldPause() { return .paused(typedCharacters: typed) }
            let front = frontmost()
            guard front?.hasPrefix(targetPrefix) == true else {
                return .lostFocus(typedCharacters: typed, frontmost: front)
            }
            poster.post(token)
            switch token {
            case .newline: typed += 1
            case .text(let run): typed += run.count
            case .delete(let count): typed += count
            }
            try? await Task.sleep(nanoseconds: interChunkNanoseconds)
        }
        return Task.isCancelled
            ? .stopped(typedCharacters: typed)
            : .completed(typedCharacters: typed)
    }

    /// Remove exactly `count` characters before the caret, through the same
    /// guarded loop `type` uses. Chunked so a long scratch checks focus and
    /// cancellation on the way, exactly as typing does.
    static func delete(
        count: Int,
        targetPrefix: String,
        poster: KeyEventPosting = CGKeyEventPoster(),
        frontmost: @Sendable () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        interChunkNanoseconds: UInt64 = 25_000_000
    ) async -> TypeResult {
        guard count > 0 else { return .completed(typedCharacters: 0) }
        var removed = 0
        let chunk = 16
        while removed < count {
            if Task.isCancelled { return .stopped(typedCharacters: removed) }
            let front = frontmost()
            guard front?.hasPrefix(targetPrefix) == true else {
                return .lostFocus(typedCharacters: removed, frontmost: front)
            }
            let step = min(chunk, count - removed)
            poster.post(.delete(count: step))
            removed += step
            try? await Task.sleep(nanoseconds: interChunkNanoseconds)
        }
        return .completed(typedCharacters: removed)
    }

    /// Honest progress phrase for partial runs: "about N words".
    static func wordsPhrase(of text: String, typedCharacters: Int) -> String {
        let prefix = String(text.prefix(typedCharacters))
        let words = prefix.split(whereSeparator: \.isWhitespace).count
        return "about \(SpokenPhrase.countWord(words)) word\(words == 1 ? "" : "s")"
    }

    /// TYPE PLAIN TEXT WHEREVER THE CURSOR IS — the narrow public entry.
    ///
    /// The full `type(_:targetPrefix:poster:…)` above takes an injected
    /// poster and answers with a partial-progress result, because the typing
    /// SKILL needs both: it can be paused mid-passage and resumed, and its
    /// tests need a poster that records instead of typing. A caller that has
    /// already selected the text it means to replace needs neither — it wants
    /// one question answered, "did the whole thing go in", and keeping that
    /// question separate is what lets the rich version stay internal.
    ///
    /// This is the prose writer's keystroke fallback and the probe's, and it
    /// lands in the target application's OWN undo stack, which is the thing a
    /// person reaches for when Mary gets it wrong.
    @discardableResult
    public static func typeIntoSelection(
        _ text: String, targetPrefix: String
    ) async -> Bool {
        if case .completed = await type(text, targetPrefix: targetPrefix) { return true }
        return false
    }
}

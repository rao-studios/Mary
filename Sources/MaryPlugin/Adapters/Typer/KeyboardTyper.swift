//
//  KeyboardTyper.swift
//  MaryBrain
//
//  WHAT: Post prose as synthetic keyboard events at the text cursor.
//  IN:   TyperPlugin+Typing / DictationRunner / ProseSurfaceWriter
//  OUT:  CGEvent HID tap
//  PIN:  Verify frontmost between chunks; check cancellation each token.
//        Newlines are Return (key 36), not unicode "\n". Lands in the app's undo.
//

import AppKit
import CoreGraphics
import Foundation

/// One typed unit: a short unicode run, a Return, or N backspaces.
enum TypeToken: Equatable, Sendable {
    case text(String)
    case newline
    /// N backspaces. Must go through this loop so the per-token frontmost check applies.
    case delete(count: Int)
}

/// Test seam: the CGEvent poster is the only non-deterministic part.
protocol KeyEventPosting: Sendable {
    func post(_ token: TypeToken)
}

/// HID-level unicode typing + Return keycodes.
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

    /// UTF-16 units per unicode key event. Bounds how much lands after a "stop".
    static let chunkLimit = 16

    /// How the run ended. `typedCharacters` is grapheme clusters actually posted.
    enum TypeResult: Equatable, Sendable {
        case completed(typedCharacters: Int)
        /// User said "stop". Remainder dropped.
        case stopped(typedCharacters: Int)
        /// Target lost frontmost. Resumable: caller saves the remainder.
        case lostFocus(typedCharacters: Int, frontmost: String?)
        /// Stage preemption. Resumable, like lostFocus.
        case paused(typedCharacters: Int)
    }

    /// Split prose into postable tokens. Never split a grapheme. "\r\n"/"\r" → one newline.
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

    /// Type at the cursor of `targetPrefix`. Call inline from a binding so "stop" reaches the loop.
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

    /// Remove `count` characters before the caret, through the same guarded loop as `type`.
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

    /// Type plain text wherever the cursor is. Whole-run Bool; the Skill uses `type` for pause/resume.
    @discardableResult
    public static func typeIntoSelection(
        _ text: String, targetPrefix: String
    ) async -> Bool {
        if case .completed = await type(text, targetPrefix: targetPrefix) { return true }
        return false
    }
}

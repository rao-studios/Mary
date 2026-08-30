//
//  PassageEditRunner+MinimalChange.swift
//  MaryAdapter
//
//  WHAT: Two-ended trim to one contiguous run, then uniqueAnchor.
//  IN:   PassageEditRunner.swift (sibling split) | PassageRefresh
//  OUT:  (anchor, replacement, range) for the writer
//  PIN:  Not a diff. Two independent edits spread the span — callers bracket.
//

import Foundation

extension PassageEditRunner {

    // MARK: - Minimal change (pure)

    /// One contiguous run that differs, located in both strings.
    /// PIN: prefix+suffix trim. Two independent edits cover both — callers bracket.
    struct ChangedSpan: Sendable, Equatable {
        /// Range in the before string. Empty for a pure insertion.
        public var before: Range<Int>
        /// Range in the after string. Empty for a pure deletion.
        public var after: Range<Int>
        /// Length delta. Negative when it shrank.
        public var delta: Int { after.count - before.count }
    }

    static func changedSpan(from current: String, to wanted: String) -> ChangedSpan {
        changedSpan(from: Array(current), to: Array(wanted))
    }

    /// Same trim over arrays so `minimalChange` does not materialize twice.
    static func changedSpan(from current: [Character], to wanted: [Character]) -> ChangedSpan {
        var head = 0
        while head < current.count, head < wanted.count, current[head] == wanted[head] {
            head += 1
        }
        var tail = 0
        while tail < current.count - head, tail < wanted.count - head,
              current[current.count - 1 - tail] == wanted[wanted.count - 1 - tail] {
            tail += 1
        }
        return ChangedSpan(
            before: head..<(current.count - tail),
            after: head..<(wanted.count - tail))
    }

    /// The smallest span of `current` that has to become something else for it
    /// to read as `wanted`, widened until it appears exactly once.
    public static func minimalChange(
        from current: String, to wanted: String
    ) -> (anchor: String, replacement: String, range: Range<Int>) {
        // Identical strings: empty span. Do not uniqueAnchor an empty no-op.
        guard current != wanted else { return ("", "", 0..<0) }
        let currentChars = Array(current)
        let wantedChars = Array(wanted)
        let changed = changedSpan(from: currentChars, to: wantedChars)
        let span = uniqueAnchor(around: changed.before, in: currentChars)
        let anchor = String(currentChars[span])
        // Replacement covers the same widened span; swallowed head/tail match in both.
        let leadIn = String(currentChars[span.lowerBound..<changed.before.lowerBound])
        let leadOut = String(currentChars[changed.before.upperBound..<span.upperBound])
        let middle = String(wantedChars[changed.after])
        return (anchor, leadIn + middle + leadOut, span)
    }

    /// Grow outward until the covered text appears once. Doubling steps.
    public static func uniqueAnchor(
        around range: Range<Int>, in characters: [Character]
    ) -> Range<Int> {
        // Body string once. Re-materializing inside the loop is quadratic.
        let body = String(characters)
        var lower = range.lowerBound
        var upper = range.upperBound
        var step = 32
        while true {
            let text = String(characters[lower..<upper])
            if !text.isEmpty, PassageWidening.occurrences(of: text, in: body).count == 1 {
                return lower..<upper
            }
            if lower == 0, upper == characters.count { return 0..<characters.count }
            lower = max(0, lower - step)
            upper = min(characters.count, upper + step)
            step *= 2
        }
    }
}

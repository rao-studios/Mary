//
//  PassageEditRunner+MinimalChange.swift
//  MaryAdapter
//
//  Split out of PassageEditRunner.swift (docs/DECOMPOSITION.md Wave 4)
//  — pure relocation, no declaration changed.
//

import Foundation

extension PassageEditRunner {

    // MARK: - Minimal change (pure)

    /// THE ONE CONTIGUOUS RUN that differs between two versions of a document,
    /// located in BOTH of them.
    ///
    /// Common prefix and common suffix off both ends is the whole computation —
    /// this is not a diff algorithm and must not become one. Both callers hand
    /// it a pair whose difference is one contiguous run BY CONSTRUCTION, and a
    /// two-ended trim finds that run exactly:
    ///
    ///   - `minimalChange` compares a document against text this system itself
    ///     replaced moments ago;
    ///   - `PassageRefresh` compares the instant before a caret write against
    ///     the instant after it, and a caret write is one insertion at one
    ///     point by definition of where the caret is.
    ///
    /// Given anything else — two independent edits in different paragraphs —
    /// the span it returns spreads to cover both, which is why `PassageRefresh`
    /// brackets the write rather than reading the body again later.
    struct ChangedSpan: Sendable, Equatable {
        /// Where the run sits in the BEFORE string. Empty for a pure insertion.
        public var before: Range<Int>
        /// Where the same run sits in the AFTER string. Empty for a pure
        /// deletion.
        public var after: Range<Int>
        /// How much longer the document got. Negative when it shrank.
        public var delta: Int { after.count - before.count }
    }

    static func changedSpan(from current: String, to wanted: String) -> ChangedSpan {
        changedSpan(from: Array(current), to: Array(wanted))
    }

    /// The same computation over arrays, so `minimalChange` — which needs both
    /// arrays anyway — does not materialize them twice on a 500,000 character
    /// body just to reach the trim.
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
        // NOTHING TO CHANGE IS ITS OWN ANSWER, and it has to be caught here
        // rather than fallen into. The two-ended trim leaves an EMPTY span for
        // identical strings, and `uniqueAnchor` is required to widen an empty
        // span — a pure insertion arrives here as one and could not be written
        // without surrounding context. So widening an empty span is right in
        // every case but this one, where it grows "nothing differs" into an
        // anchor and a replacement that are the same words. `revert` would then
        // hand a writer a no-op substitution: on Xcode a real disk write that
        // moves the file's mtime, on Pages an AX select-and-set round trip that
        // can fall back to synthesised keystrokes — all to change nothing, and
        // the "already reads the way it did before" sentence its own guard was
        // written to produce would never be spoken.
        guard current != wanted else { return ("", "", 0..<0) }
        let currentChars = Array(current)
        let wantedChars = Array(wanted)
        let changed = changedSpan(from: currentChars, to: wantedChars)
        let span = uniqueAnchor(around: changed.before, in: currentChars)
        let anchor = String(currentChars[span])
        // The replacement is whatever `wanted` holds across the SAME widened
        // span — the head and tail the widening swallowed are identical in both
        // strings by construction, so carrying them along changes nothing about
        // the result and everything about whether the anchor can be found.
        let leadIn = String(currentChars[span.lowerBound..<changed.before.lowerBound])
        let leadOut = String(currentChars[changed.before.upperBound..<span.upperBound])
        let middle = String(wantedChars[changed.after])
        return (anchor, leadIn + middle + leadOut, span)
    }

    /// Grow a span outward until the text it covers appears exactly once.
    ///
    /// A MINIMAL ANCHOR IS OFTEN AMBIGUOUS, and ambiguity is what the writers
    /// refuse: putting back the word "the" would hand them an anchor with four
    /// hundred occurrences. Growing by whole doublings rather than one
    /// character at a time keeps this logarithmic in the document — a 500,000
    /// character body is at most fourteen rounds — and stopping at the first
    /// unique span keeps the replacement as small as it can honestly be.
    public static func uniqueAnchor(
        around range: Range<Int>, in characters: [Character]
    ) -> Range<Int> {
        // Built ONCE. `occurrences` takes a `String`, and re-materializing the
        // whole document inside the loop would turn a logarithmic search into a
        // quadratic one on the largest bodies this system reads.
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

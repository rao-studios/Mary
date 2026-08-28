//
//  CorpusPatterns.swift
//  MaryPlugin
//
//  COMPILING AND RUNNING WHAT A PACKAGE DECLARED.
//
//  Every regular expression here came out of a `.mary` file, which is the
//  reason for the two rules this type exists to enforce.
//
//  COMPILED ONCE AND CACHED. A crawl runs every declared pattern over every
//  file in a neighbourhood — a dozen patterns across two dozen files is a few
//  hundred compilations of the same handful of expressions if nothing
//  remembers them. The validator already proved they compile at admission; the
//  cache is about not paying for it again.
//
//  A FAILURE HERE IS SILENCE, NOT A CRASH. The validator refuses a package
//  whose patterns do not compile, so anything reaching this file has already
//  been checked. If one somehow has not, the honest answer is zero matches —
//  the corpus learns less than it could, which is what a missing pattern
//  always means, and never a crash on a background poll.
//

import Foundation
import os

public enum CorpusPatterns {

    private static let cache = OSAllocatedUnfairLock<[String: NSRegularExpression]>(
        initialState: [:])

    /// Nil for a pattern that will not compile — see the header on why that is
    /// silence rather than a throw.
    public static func expression(_ pattern: String) -> NSRegularExpression? {
        if let cached = cache.withLock({ $0[pattern] }) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache.withLock { $0[pattern] = compiled }
        return compiled
    }

    /// How many times `pattern` occurs in `text`.
    public static func count(_ pattern: String, in text: String) -> Int {
        guard !text.isEmpty, let expression = expression(pattern) else { return 0 }
        return expression.numberOfMatches(
            in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Every first-capture-group value `pattern` finds in `text`, in order.
    ///
    /// THE FIRST GROUP AND NOT THE WHOLE MATCH, because a relation pattern's
    /// job is to name a thing: `\bstruct\s+(\w+)` finds a declaration and the
    /// NAME is the part worth having. The validator insists relation patterns
    /// capture for exactly this reason.
    public static func captures(_ pattern: String, in text: String) -> [String] {
        guard !text.isEmpty, let expression = expression(pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: full).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
    }
}

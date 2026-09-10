//
//  CorpusPatterns.swift
//  MaryPlugin
//
//  WHAT: Compile and run package-declared regular expressions.
//  IN:   PluginCorpusSchema / CorpusCrawl / CorpusStyleReader
//  OUT:  cached NSRegularExpression
//  PIN:  Compile once and cache. Failure is silence (zero matches), not a crash.
//

import Foundation
import os

public enum CorpusPatterns {

    private static let cache = OSAllocatedUnfairLock<[String: NSRegularExpression]>(
        initialState: [:])

    /// Nil if the pattern will not compile — silence, not a throw.
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

    /// First-capture-group values, in order. PIN: the name, not the whole match.
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

    /// One capture plus the 1-based line it starts on.
    public struct PositionedCapture: Sendable, Equatable {
        public let name: String
        public let line: Int
    }

    /// Same cache as `captures`, plus line numbers — for an outline a person reads.
    public static func capturesWithLines(_ pattern: String, in text: String) -> [PositionedCapture] {
        guard !text.isEmpty, let expression = expression(pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: full).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            let line = text[text.startIndex..<range.lowerBound].reduce(1) {
                $1 == "\n" ? $0 + 1 : $0
            }
            return PositionedCapture(name: String(text[range]), line: line)
        }
    }
}

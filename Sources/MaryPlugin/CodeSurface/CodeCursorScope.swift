//
//  CodeCursorScope.swift
//  MaryPlugin
//
//  WHAT: Declarations still open above the caret.
//  IN:   live buffer + CodeSurfaceRegistration regexes
//  OUT:  CodeSurfaceObserver liveWork

import Foundation
import MaryFoundation

public enum CodeCursorScope {

    /// The furthest a scope read will look backwards from the caret.
    public static let scopePrefixCap = 120_000

    /// The most links a scope line will name. Three is a location; six is an
    /// outline, and `list_declarations` already exists for that.
    public static let maximumChainDepth = 3

    /// What one reading of a caret found. `line` is measured; `chain` is
    /// inferred (see the header); `excerpt` is the application's own text.
    public struct Reading: Sendable, Equatable {
        public var line: Int
        public var chain: [String]
        public var excerpt: String

        public init(line: Int, chain: [String], excerpt: String) {
            self.line = line
            self.chain = chain
            self.excerpt = excerpt
        }
    }

    // MARK: - Where the caret is

    /// The 1-based line the caret sits on, counted from the text before it.
    public static func lineNumber(before caret: String) -> Int {
        caret.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// Leading-whitespace width of every 1-based line in `text`, and whether the line
    /// carries anything else — a flat array the chain walk indexes into.
    static func indentations(of text: String) -> [(indent: Int, isEmpty: Bool)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            return (
                indent: leading.reduce(0) { $1 == "\t" ? $0 + 4 : $0 + 1 },
                isEmpty: line.isEmpty)
        }
    }

    /// The column the caret is standing in, for rule 2. The lines here are the PREFIX's, so
    /// the last one is the caret's own line truncated AT the caret.
    static func caretIndent(in indentedLines: [(indent: Int, isEmpty: Bool)]) -> Int {
        for line in indentedLines.reversed() where !line.isEmpty {
            return line.indent
        }
        return 0
    }

    /// The declarations still open at the caret, outermost first.
    static func chain(
        declarations: [CorpusPatterns.PositionedCapture],
        indentations: [Int],
        caretLine: Int,
        caretIndent: Int,
        maximumDepth: Int = maximumChainDepth
    ) -> [CorpusPatterns.PositionedCapture] {
        var chain: [CorpusPatterns.PositionedCapture] = []
        var innermostIndent = Int.max
        for declaration in declarations.reversed() {
            let index = declaration.line - 1
            guard index >= 0, index < indentations.count else { continue }
            let indent = indentations[index]
            // RULE 2 — nothing at or beyond the caret's own column encloses
            // it, unless it is the thing the caret is standing in the middle
            // of declaring.
            guard declaration.line == caretLine || indent < caretIndent else { continue }
            // RULE 1 — strictly smaller, so a sibling that has already closed
            // at the same indentation is skipped and a genuine parent is kept.
            guard indent < innermostIndent else { continue }
            chain.insert(declaration, at: 0)
            innermostIndent = indent
        }
        // The INNERMOST links survive a depth trim: "…→ Reading → excerpt"
        // locates a caret; the file's outermost namespace usually does not.
        return Array(chain.suffix(maximumDepth))
    }

    /// The whole reading, from the text before the caret and the text around it.
    public static func reading(
        prefix: String,
        excerpt: String,
        patterns: [String]
    ) -> Reading {
        let line = lineNumber(before: prefix)
        let found = CodeSurfaceAdapter.declarations(in: prefix, patterns: patterns)
        let lines = indentations(of: prefix)
        let open = chain(
            declarations: found,
            indentations: lines.map(\.indent),
            caretLine: line,
            caretIndent: caretIndent(in: lines))
        return Reading(line: line, chain: open.map(\.name), excerpt: excerpt)
    }

    // MARK: - What it says

    /// A chain that resolved to nothing says the line ALONE rather than nothing at all:
    /// "the caret is on line 412 of this file" is a true, useful statement, and dropping it
    /// because the inference failed would throw away the measured half with the guessed
    public static func scopeLine(_ reading: Reading) -> String {
        guard !reading.chain.isEmpty else { return "Cursor at line \(reading.line)" }
        return "Cursor scope: \(reading.chain.joined(separator: " → ")) (line \(reading.line))"
    }

    /// The fact's whole content: the scope line, then the text.
    public static func content(_ reading: Reading) -> String {
        let scope = scopeLine(reading)
        let body = reading.excerpt.trimmingCharacters(in: .newlines)
        return body.isEmpty ? scope : scope + "\n" + body
    }

    /// The speaking lane's live section: file, scope, excerpt. No application named.
    public static func liveWork(
        editorName: String,
        fileName: String,
        content: String
    ) -> String {
        var lines = [
            "Current file:",
            fileName,
            "In \(editorName).",
        ]
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let scope = parts.first.map(String.init) ?? content
        if !scope.isEmpty { lines.append(scope) }
        let body = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .newlines) : ""
        if !body.isEmpty {
            if let line = lineNumber(inScopeLine: scope) {
                lines.append("What they see (from line \(line)):\n\(body)")
            } else {
                lines.append("What they see:\n\(body)")
            }
        }
        lines.append(
            "\"this\" / \"here\" / \"what I just wrote\" refer to this file and selection.")
        lines.append(
            "This snapshot is LIVE and supersedes anything earlier in the conversation about this file — treat older reads of it as stale.")
        return lines.joined(separator: "\n")
    }

    /// The measured line out of a scope line this file itself minted.
    static func lineNumber(inScopeLine scope: String) -> Int? {
        guard let match = scope.range(of: #"line (\d+)"#, options: .regularExpression)
        else { return nil }
        let digits = scope[match].split(separator: " ").last.map(String.init) ?? ""
        return Int(digits)
    }

    // MARK: - The window around the caret

    /// The character range to read around `caret`, centred on it and clipped to the
    /// document.
    public static func window(around caret: Int, total: Int, budget: Int) -> Range<Int> {
        let budget = max(0, min(budget, total))
        let caret = max(0, min(caret, total))
        var start = max(0, caret - budget / 2)
        let end = min(total, start + budget)
        start = max(0, end - budget)
        return start..<end
    }

    /// The window's text with its broken first and last lines removed, so an excerpt reads
    /// as code rather than as a slice.
    public static func snapped(
        _ text: String, cutAtStart: Bool, cutAtEnd: Bool
    ) -> String {
        var text = Substring(text)
        if cutAtStart, let newline = text.firstIndex(of: "\n") {
            let trimmed = text[text.index(after: newline)...]
            if !trimmed.isEmpty { text = trimmed }
        }
        if cutAtEnd, let newline = text.lastIndex(of: "\n") {
            let trimmed = text[..<newline]
            if !trimmed.isEmpty { text = trimmed }
        }
        return String(text)
    }
}

//
//  CodeCursorScope.swift
//  MaryPlugin
//
//  WHAT THE TEXT AROUND AN INSERTION POINT SAYS ABOUT WHERE THE USER IS —
//  pure string work, no Accessibility, so every rule below is pinned by a
//  unit test rather than only by a live pass.
//
//  THE PARSING IS BORROWED, NOT WRITTEN. `[Corpus T]` already built
//  `list_declarations` over `CorpusPatterns.capturesWithLines` running the
//  patterns `xcode.mary` declares in `corpus.relations.declarations`; the
//  enclosing scope of a cursor is the same question asked from the other
//  end — the last declaration at or above the caret, plus its ancestors. So
//  this file runs `CodeSurfaceAdapter.declarations(in:patterns:)`, the exact
//  function that backs that Skill, and adds only the two things a cursor
//  needs and an outline does not: which declarations still ENCLOSE the caret,
//  and a window of text around it.
//
//  ANCESTRY COMES FROM INDENTATION, and it is worth being explicit that this
//  is an approximation with a known shape rather than a parser. A declared
//  regex knows a declaration's NAME and its LINE; it does not know where the
//  declaration's braces close, so "is this one still open at the caret" is
//  not a question the declared patterns can answer. Leading whitespace can,
//  under TWO rules, and the second was found live rather than reasoned out:
//
//    1. Walking the declarations above the caret in reverse and keeping only
//       those whose indentation strictly DECREASES. This skips a sibling that
//       has already closed, because a sibling sits at the same indentation as
//       its successor rather than a smaller one.
//    2. Nothing indented at or beyond the CARET'S OWN column can enclose it.
//
//  Rule 1 alone was wrong in a way rule 2 fixes exactly. Measured against a
//  real editor: the caret sat at column 4 inside a `private var` — a member
//  `xcode.mary` declares no pattern for — and the nearest declaration above it
//  was a nested `func` at column 8, closed a hundred and seventy lines
//  earlier. Rule 1 had nothing later at a smaller indent to knock it out, so
//  the scope line confidently named a function the caret was nowhere inside.
//  Rule 2 answers it directly: a declaration at column 8 cannot contain
//  something at column 4. What survives is the type at column 0, which is the
//  true and useful answer. A declaration ON the caret's own line is the one
//  exception — the caret is inside what it is declaring.
//
//  WHERE IT IS WRONG: a file indented inconsistently, or with a declaration
//  inside a string or a comment, can name a scope that is not the caret's.
//  That is why the scope line says "Cursor scope" and carries the line number
//  beside it — the line is measured, the chain is inferred, and the model can
//  always call `read_buffer` for the authority. A wrong GUESS presented as a
//  measurement is the failure this comment exists to prevent; the honest
//  fallback, taken whenever no declaration is found at all, is to say only
//  the line number.
//

import Foundation
import MaryFoundation

public enum CodeCursorScope {

    /// The furthest a scope read will look backwards from the caret.
    ///
    /// The enclosing chain lives ABOVE the caret and its outermost link is
    /// usually at the top of the file, so the prefix has to start at 0 — there
    /// is no window that both finds `struct Foo` on line 12 and a `func` on
    /// line 900. What bounds the cost instead is the file: past this many
    /// characters the scope line is DROPPED rather than computed from a
    /// truncated prefix, because a chain read from the middle of a file is
    /// exactly the confident wrong answer the header refuses. The excerpt
    /// still publishes — it is windowed on the caret and never needed the
    /// prefix at all.
    ///
    /// Sized well above `xcode.mary`'s own 20 000-character whole-document
    /// budget and far below `CodeSurfaceAX.bodyCap`: it is a ceiling on a
    /// background poll, not a statement about how much of a file is readable.
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

    /// Leading-whitespace width of every 1-based line in `text`, and whether
    /// the line carries anything else — a flat array the chain walk indexes
    /// into. A tab counts as four columns, which only has to be CONSISTENT:
    /// the walk compares indentations against each other, never against an
    /// absolute.
    static func indentations(of text: String) -> [(indent: Int, isEmpty: Bool)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            return (
                indent: leading.reduce(0) { $1 == "\t" ? $0 + 4 : $0 + 1 },
                isEmpty: line.isEmpty)
        }
    }

    /// The column the caret is standing in, for rule 2.
    ///
    /// The lines here are the PREFIX's, so the last one is the caret's own
    /// line truncated AT the caret — which means its leading-whitespace width
    /// is the caret's actual column in every case but one. A caret sitting in
    /// the indentation itself measures as exactly that indentation, which is
    /// correct and is the case a first version of this got wrong: it treated
    /// any whitespace-only line as unknown and looked upwards, which for a
    /// caret at column 12 inside a body borrowed the enclosing declaration's
    /// own column 8 and then excluded that very declaration.
    ///
    /// THE ONE EXCEPTION is an EMPTY last line — the caret at column 0 of a
    /// line not yet typed. Column 0 would knock every declaration out and
    /// leave a bare line number, so the nearest preceding line with any
    /// content answers instead: that is the block the user is standing in,
    /// which is the question rule 2 is asking.
    static func caretIndent(in indentedLines: [(indent: Int, isEmpty: Bool)]) -> Int {
        for line in indentedLines.reversed() where !line.isEmpty {
            return line.indent
        }
        return 0
    }

    /// The declarations still open at the caret, outermost first.
    ///
    /// See the header for why indentation answers this, what the declared
    /// patterns cannot answer, and which live failure rule 2 exists to close.
    /// `declarations` must be ordered by line ascending, which is what
    /// `CodeSurfaceAdapter.declarations(in:patterns:)` returns.
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

    /// The whole reading, from the text before the caret and the text around
    /// it. `prefix` nil means the file was longer than `scopePrefixCap` and
    /// no chain is claimed — the line number is then unknown too, so the
    /// caller passes the line it measured some other way or accepts zero.
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

    /// The scope line the prompt carries — Bonnie's own "Cursor scope: struct
    /// X → var body" shape, with the measured line beside the inferred chain.
    ///
    /// A chain that resolved to nothing says the line ALONE rather than
    /// nothing at all: "the caret is on line 412 of this file" is a true,
    /// useful statement, and dropping it because the inference failed would
    /// throw away the measured half with the guessed one.
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

    // MARK: - The window around the caret

    /// The character range to read around `caret`, centred on it and clipped
    /// to the document. `budget` is the package's own declared
    /// `ambientExcerptCharacters` — the number that exists to say how much of
    /// the front document may ride along on every turn whether or not anyone
    /// asked, which is exactly what this is.
    ///
    /// CENTRED, THEN RE-SPENT AT THE EDGES: a caret ten characters into a file
    /// spends the whole budget forwards rather than losing half of it to text
    /// that does not exist, which is what a naive ±half window does.
    public static func window(around caret: Int, total: Int, budget: Int) -> Range<Int> {
        let budget = max(0, min(budget, total))
        let caret = max(0, min(caret, total))
        var start = max(0, caret - budget / 2)
        let end = min(total, start + budget)
        start = max(0, end - budget)
        return start..<end
    }

    /// The window's text with its broken first and last lines removed, so an
    /// excerpt reads as code rather than as a slice.
    ///
    /// Only the ends that were CUT are trimmed: a window that reaches the
    /// start or the end of the document has no broken line there, and eating
    /// its first real line would lose the very declaration the caret sits
    /// under. A trim that would empty the excerpt is not taken.
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

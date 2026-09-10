//
//  CorpusTracer.swift
//  MaryPlugin
//
//  WHAT: What reaches a declaration, what it reaches, and where words land.
//  IN:   CorpusTextCache / CorpusDeclarationIndex / declared `relations`
//  OUT:  TraceHit (file, line, the line itself, the declaration it sits in)
//  PIN:  Caps are the feature — `CorpusCrawl`'s own words. A trace is a
//        BEARING, not a report: eight hits a person can hold beat forty they
//        cannot. Language-agnostic: the project's declared grammar decides
//        what a reference looks like, and the symbol's own name supplies the
//        rest, so a second notation needs no case here.
//

import Foundation
import MaryFoundation

/// One place a trace landed.
public struct TraceHit: Sendable, Equatable {
    public let relativePath: String
    /// 1-based.
    public let line: Int
    /// The matching line itself, trimmed and clipped.
    public let snippet: String
    /// The declaration this line sits inside, when the index can name one.
    public let enclosing: String?

    public init(relativePath: String, line: Int, snippet: String, enclosing: String?) {
        self.relativePath = relativePath
        self.line = line
        self.snippet = snippet
        self.enclosing = enclosing
    }
}

public enum CorpusTracer {

    /// How many hits one question is worth.
    public static let hitLimit = 8
    /// How many from any single file, so one busy file cannot be the answer.
    public static let perFileLimit = 3
    /// How much of a line is worth showing.
    public static let snippetLimit = 160

    // MARK: - Who reaches this

    /// Where a declared name is used across the project.
    ///
    /// The patterns are derived from the NAME, not from a language: a call
    /// (`name(`), a member (`.name`), and — for a name that looks like a type
    /// — a bare mention. The declared `references` grammar is not enough on
    /// its own here: a corpus that captures `[A-Z]\w*\(` finds types and
    /// initializers and never a lower-case function, which is most of what a
    /// person asks "who calls this" about.
    /// A CALLER IN THE SAME FILE IS STILL A CALLER — and often the only one
    /// that matters: a private helper called twice from the function above it
    /// reported "nothing reaches this" while its own caller sat six lines
    /// away. `excluding` is for a caller that genuinely wants a file left out;
    /// the declaration itself is excluded by identity, not by file.
    public static func callers(
        of name: String,
        root: String,
        corpus: PluginCorpusSchema,
        excluding excludedPath: String? = nil,
        declarations: CorpusDeclarationIndex,
        text: CorpusTextCache = .shared,
        limit: Int = hitLimit,
        at now: Date = Date()
    ) -> [TraceHit] {
        guard let expression = usePattern(for: name) else { return [] }
        var hits: [TraceHit] = []
        for relativePath in text.files(root: root, corpus: corpus, at: now) {
            guard hits.count < limit else { break }
            guard let file = text.text(
                relativePath: relativePath, root: root, corpus: corpus, at: now)
            else { continue }
            // The code slice: a name in a comment or a string is not a caller.
            let lines = file.source.split(separator: "\n", omittingEmptySubsequences: false)
            var perFile = 0
            for capture in CorpusPatterns.capturesWithLines(expression, in: file.code) {
                guard hits.count < limit, perFile < perFileLimit else { break }
                let index = capture.line - 1
                guard index >= 0, index < lines.count else { continue }
                // The declaration itself is not one of its own callers.
                if relativePath == excludedPath || isDeclaration(
                    of: name, at: capture.line, in: relativePath, declarations: declarations) {
                    continue
                }
                perFile += 1
                hits.append(TraceHit(
                    relativePath: relativePath,
                    line: capture.line,
                    snippet: clipped(String(lines[index])),
                    enclosing: declarations.nearest(
                        in: relativePath, line: capture.line)?.name))
            }
        }
        return hits
    }

    // MARK: - What this reaches

    /// The project's own declarations a body reaches, resolved to where they
    /// live. Names the project does not declare are dropped — a trace of the
    /// standard library is noise wearing a bearing's clothes.
    public static func callees(
        in body: String,
        own name: String,
        corpus: PluginCorpusSchema,
        declarations: CorpusDeclarationIndex,
        /// The file the body came from. A namesake here is the one meant —
        /// without it, `promptContribution` inside one observer resolved to a
        /// DIFFERENT observer's method purely because that file sorts earlier,
        /// which is a confident wrong answer of exactly the kind a trace
        /// exists to prevent.
        in relativePath: String? = nil,
        limit: Int = hitLimit
    ) -> [TraceHit] {
        let code = CorpusText(source: body, filename: "").code
        var names: [String] = []
        var seen: Set<String> = [name]
        for pattern in corpus.relations.references + Self.calleePatterns {
            for captured in CorpusPatterns.captures(pattern, in: code)
            where seen.insert(captured).inserted {
                names.append(captured)
            }
        }
        var hits: [TraceHit] = []
        for candidate in names {
            guard hits.count < limit else { break }
            let rivals = declarations.declarations(named: candidate)
            guard let declaration = rivals.first(where: {
                $0.relativePath == relativePath
            }) ?? rivals.first
            else { continue }
            hits.append(TraceHit(
                relativePath: declaration.relativePath,
                line: declaration.line,
                snippet: clipped(declaration.header),
                enclosing: declaration.name))
        }
        return hits
    }

    // MARK: - Where the words land

    /// Lines in the project that match what the user actually said.
    public static func search(
        for query: String,
        root: String,
        corpus: PluginCorpusSchema,
        declarations: CorpusDeclarationIndex,
        text: CorpusTextCache = .shared,
        limit: Int = hitLimit,
        at now: Date = Date()
    ) -> [TraceHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [TraceHit] = []
        for relativePath in text.files(root: root, corpus: corpus, at: now) {
            guard hits.count < limit else { break }
            guard let file = text.text(
                relativePath: relativePath, root: root, corpus: corpus, at: now)
            else { continue }
            var perFile = 0
            var line = 0
            for raw in file.source.split(
                separator: "\n", omittingEmptySubsequences: false) {
                line += 1
                guard hits.count < limit, perFile < perFileLimit else { break }
                guard raw.range(
                    of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                else { continue }
                perFile += 1
                hits.append(TraceHit(
                    relativePath: relativePath,
                    line: line,
                    snippet: clipped(String(raw)),
                    enclosing: declarations.nearest(in: relativePath, line: line)?.name))
            }
        }
        return hits
    }

    /// The words in an utterance worth searching for — the ones that carry the
    /// subject. Short and closed: everything else is what English does between
    /// them.
    public static func contentWords(of utterance: String, limit: Int = 3) -> [String] {
        let words = utterance
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init)
            .filter { $0.count > 3 && !stopWords.contains($0) }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    // MARK: - Patterns

    /// Uses of one name: a call, a member access, and — for a Capitalized
    /// name — a bare mention, which is how a type is used at all.
    static func usePattern(for name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard !escaped.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }
        if name.first?.isUppercase == true {
            return "(?<![A-Za-z0-9_])(\(escaped))(?![A-Za-z0-9_])"
        }
        // A CALL, however it is reached. The lookbehind excludes only
        // identifier characters, NOT the dot — `reader.read()` is a call of
        // `read` and excluding the dot made every member call invisible,
        // which is most of what "who calls this" is asked about. `spread(`
        // still cannot match, because `a` is an identifier character.
        return "(?<![A-Za-z0-9_])(\(escaped))\\s*\\("
    }

    /// What a body reaches, when the corpus' own grammar is type-shaped: a
    /// call by any name, and a member call.
    static let calleePatterns = [
        "(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\\s*\\(",
        "\\.([a-z][A-Za-z0-9_]*)\\s*\\(",
    ]

    static func isDeclaration(
        of name: String, at line: Int, in relativePath: String,
        declarations: CorpusDeclarationIndex
    ) -> Bool {
        declarations.declarations(named: name).contains {
            $0.relativePath == relativePath && $0.line == line
        }
    }

    static func clipped(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > snippetLimit else { return trimmed }
        return String(trimmed.prefix(snippetLimit - 1)) + "…"
    }

    /// Deliberately short. A longer list starts deciding what a person meant.
    static let stopWords: Set<String> = [
        "this", "that", "these", "those", "what", "when", "where", "which",
        "with", "from", "into", "about", "here", "there", "they", "them",
        "their", "your", "yours", "mine", "does", "doing", "done", "have",
        "having", "just", "like", "look", "looking", "make", "makes", "made",
        "much", "must", "need", "over", "some", "such", "than", "then",
        "think", "thing", "things", "time", "very", "want", "well", "were",
        "will", "would", "could", "should", "code", "file", "line", "lines",
    ]
}

//
//  EnclosingUnit.swift
//  MaryPlugin
//
//  WHAT: The whole declaration or passage a caret sits inside.
//  IN:   live buffer or file text + the corpus' declared grammar
//  OUT:  AwarenessAdapter / AwarenessObserver
//  PIN:  A WINDOW IS NOT A UNIT. `CodeCursorScope` answers "what is around the
//        caret" in characters; this answers "what is the caret INSIDE" in
//        declarations, and the difference is the whole point — a function cut
//        off mid-body reads as broken code and gets talked about as if it were.
//        Swift gets brace-exact spans; every other notation gets the declared
//        grammar plus indentation, which is honest and coarse.
//

import Foundation
import MaryFoundation

public struct EnclosingUnit: Sendable, Equatable {

    /// The innermost declaration's name — "refreshAmbientContext".
    public let name: String
    /// Its kind word, as the grammar spelled it — "func", "struct".
    public let kind: String
    /// Outermost first: ["CorpusObserver", "refreshAmbientContext"].
    public let chain: [String]
    /// 1-based, inclusive.
    public let startLine: Int
    public let endLine: Int
    /// The unit's own text, truncated only if it is enormous.
    public let body: String
    /// Whether `body` is the whole unit or a truncation of it.
    public let isWhole: Bool

    public init(
        name: String, kind: String, chain: [String],
        startLine: Int, endLine: Int, body: String, isWhole: Bool
    ) {
        self.name = name
        self.kind = kind
        self.chain = chain
        self.startLine = startLine
        self.endLine = endLine
        self.body = body
        self.isWhole = isWhole
        }

    /// How the unit reads when named — "func refreshAmbientContext".
    public var display: String {
        name.isEmpty ? kind : "\(kind) \(name)"
    }

    /// The scope, spoken: "CorpusObserver → refreshAmbientContext".
    public var scope: String {
        chain.isEmpty ? display : chain.joined(separator: " → ")
    }

    /// The most a single unit may contribute. A declaration longer than this
    /// is a file's worth of code and the head of it is what says what it is.
    public static let characterBudget = 6000

    // MARK: - Locating

    /// The unit `caret` is inside, or nil when nothing encloses it.
    ///
    /// `highlight` marks the user's own selection inside the body, because a
    /// unit read for a highlighted line has to say WHICH line was highlighted
    /// or the answer drifts to the whole function.
    public static func locate(
        in text: String,
        caret: Int,
        corpus: PluginCorpusSchema?,
        highlight: Range<Int>? = nil
    ) -> EnclosingUnit? {
        guard !text.isEmpty else { return nil }
        let caret = max(0, min(caret, text.count))
        if corpus?.notation == "swift",
           let unit = swiftUnit(in: text, caret: caret, highlight: highlight) {
            return unit
        }
        return declaredUnit(
            in: text, caret: caret,
            patterns: corpus?.relations.declarations ?? [],
            highlight: highlight)
    }

    /// Brace-exact: the innermost span `SwiftSymbolLocator` already computes
    /// for the caret, reused rather than re-derived.
    private static func swiftUnit(
        in text: String, caret: Int, highlight: Range<Int>?
    ) -> EnclosingUnit? {
        let spans = SwiftSymbolLocator.scopeChain(at: caret, in: text)
        // THE LINE THEY ARE STANDING ON. A brace walk can only report what is
        // already OPEN at an offset, so a caret resting on `func read() {`
        // itself — the commonest place for a caret to be, because they just
        // wrote it or just clicked it — reports the enclosing TYPE and hands
        // back six thousand characters of class instead of the function they
        // are looking at. `CodeCursorScope.chain` has always made the same
        // exception ("unless it is the thing the caret is standing in the
        // middle of declaring"); this is that rule, applied to spans.
        if let starting = declarationStarting(onLineOf: caret, in: text),
           spans.last.map({ $0.name != starting.name }) ?? true {
            return unit(from: starting, chain: spans.map(\.display) + [starting.display],
                        in: text, highlight: highlight)
        }
        guard let innermost = spans.last else { return nil }
        return unit(from: innermost, chain: spans.map(\.display),
                    in: text, highlight: highlight)
    }

    /// One span, rendered as a unit.
    private static func unit(
        from span: SymbolSpan, chain: [String], in text: String, highlight: Range<Int>?
    ) -> EnclosingUnit? {
        let start = span.declStart
        let end = span.fullEnd
        guard start < end else { return nil }
        let startOffset = text.distance(from: text.startIndex, to: start)
        let endOffset = text.distance(from: text.startIndex, to: end)
        let body = marked(
            String(text[start..<end]),
            highlight: highlight.map {
                (max(0, $0.lowerBound - startOffset))..<(max(0, $0.upperBound - startOffset))
            },
            length: endOffset - startOffset)
        let budgeted = TextBudget.truncate(body, limit: characterBudget)
        return EnclosingUnit(
            name: span.name,
            kind: span.kind,
            chain: chain,
            startLine: line(of: startOffset, in: text),
            endLine: line(of: max(startOffset, endOffset - 1), in: text),
            body: budgeted,
            isWhole: budgeted.count == body.count)
    }

    /// The declaration whose own header sits on the caret's line, if any.
    /// Ambiguity yields nothing rather than a guess — `SwiftSymbolLocator`'s
    /// own three-valued answer, honoured.
    private static func declarationStarting(
        onLineOf caret: Int, in text: String
    ) -> SymbolSpan? {
        let caretLine = line(of: caret, in: text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard caretLine - 1 >= 0, caretLine - 1 < lines.count else { return nil }
        let source = String(lines[caretLine - 1])
        guard let match = source.range(
            of: #"\b(?:func|struct|class|enum|actor|protocol|extension|init|subscript)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            options: .regularExpression)
        else { return nil }
        let name = source[match]
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .last
            .map { String($0.prefix { $0.isLetter || $0.isNumber || $0 == "_" }) }
        guard let name, !name.isEmpty,
              case .found(let span) = SwiftSymbolLocator.locate(symbol: name, in: text)
        else { return nil }
        // It must really start here — a same-named declaration elsewhere is
        // not the one they are standing on.
        let startLine = line(
            of: text.distance(from: text.startIndex, to: span.declStart), in: text)
        guard startLine <= caretLine, caretLine <= startLine + 3 else { return nil }
        return span
    }

    /// Every other notation: the declared grammar says where units START, and
    /// indentation says where this one ends — the next line at or left of the
    /// declaration's own column.
    private static func declaredUnit(
        in text: String, caret: Int, patterns: [String], highlight: Range<Int>?
    ) -> EnclosingUnit? {
        guard !patterns.isEmpty else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let caretLine = line(of: caret, in: text)
        let masked = CorpusText(source: text, filename: "").code
        // AT OR ABOVE THE CARET ONLY. `CodeCursorScope.chain` is written for a
        // PREFIX — the text before the caret — and reads its last declaration
        // as the innermost one. Handed the whole file it happily reports a
        // declaration BELOW the caret as the one enclosing it.
        var declarations: [CorpusPatterns.PositionedCapture] = []
        var seen = Set<Int>()
        for pattern in patterns {
            for capture in CorpusPatterns.capturesWithLines(pattern, in: masked)
            where capture.line <= caretLine && seen.insert(capture.line).inserted {
                declarations.append(capture)
            }
        }
        guard !declarations.isEmpty else { return nil }
        let indents = CodeCursorScope.indentations(of: text).map(\.indent)
        let chain = CodeCursorScope.chain(
            declarations: declarations.sorted { $0.line < $1.line },
            indentations: indents,
            caretLine: caretLine,
            caretIndent: caretLine - 1 < indents.count ? indents[caretLine - 1] : 0,
            maximumDepth: CodeCursorScope.maximumChainDepth)
        guard let innermost = chain.last else { return nil }

        let startIndex = innermost.line - 1
        guard startIndex >= 0, startIndex < lines.count else { return nil }
        let openIndent = indents[startIndex]
        var endIndex = lines.count - 1
        var cursor = startIndex + 1
        while cursor < lines.count {
            let line = lines[cursor]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty,
               indents[cursor] <= openIndent {
                endIndex = cursor - 1
                break
            }
            cursor += 1
        }
        let body = lines[startIndex...min(endIndex, lines.count - 1)]
            .joined(separator: "\n")
        let startOffset = offset(ofLine: innermost.line, in: lines)
        let marked = marked(
            body,
            highlight: highlight.map {
                (max(0, $0.lowerBound - startOffset))..<(max(0, $0.upperBound - startOffset))
            },
            length: body.count)
        let budgeted = TextBudget.truncate(marked, limit: characterBudget)
        return EnclosingUnit(
            name: innermost.name,
            kind: "declaration",
            chain: chain.map(\.name),
            startLine: innermost.line,
            endLine: min(endIndex, lines.count - 1) + 1,
            body: budgeted,
            isWhole: budgeted.count == marked.count)
    }

    // MARK: - Helpers

    /// The user's own highlight, marked inside the unit — `[[…]]`, the same
    /// bracket `read_selection` already speaks.
    static func marked(
        _ body: String, highlight: Range<Int>?, length: Int
    ) -> String {
        guard let highlight, !highlight.isEmpty,
              highlight.lowerBound >= 0, highlight.upperBound <= length,
              highlight.upperBound <= body.count
        else { return body }
        let lower = body.index(body.startIndex, offsetBy: highlight.lowerBound)
        let upper = body.index(body.startIndex, offsetBy: highlight.upperBound)
        return String(body[body.startIndex..<lower])
            + "[[" + String(body[lower..<upper]) + "]]"
            + String(body[upper...])
    }

    /// 1-based line of a character offset.
    static func line(of offset: Int, in text: String) -> Int {
        guard offset > 0 else { return 1 }
        let limit = min(offset, text.count)
        let index = text.index(text.startIndex, offsetBy: limit)
        return text[text.startIndex..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// Character offset a 1-based line starts at.
    static func offset(ofLine line: Int, in lines: [String]) -> Int {
        guard line > 1 else { return 0 }
        return lines.prefix(line - 1).reduce(0) { $0 + $1.count + 1 }
    }
}

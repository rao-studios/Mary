//
//  SwiftSymbolLocator.swift
//  MaryPlugin
//
//  WHAT: Coarse Swift declaration span (mask, header regex, braces).
//  OUT:  CodeSurfaceEdit
//  PIN:  Not SwiftSyntax. Soft-fail → additive edit, never a bad splice.

import Foundation

public extension SymbolSpan {
    /// "struct SettingsSheet", "var body", "init" — how a chain entry reads.
    var display: String {
        name.isEmpty ? kind : "\(kind) \(name)"
    }
}

public struct SymbolSpan: Equatable {
    /// Start of the declaration including any leading attributes / doc comments.
    public var declStart: String.Index
    /// The opening brace of the body (nil for brace-less declarations like a
    /// protocol requirement or a stored property).
    public var bodyOpen: String.Index?
    /// One past the end of the whole declaration (the matching `}` for braced
    /// decls, or end of the statement line for brace-less ones).
    public var fullEnd: String.Index
    public var kind: String
    public var name: String
}

public enum LocateResult: Equatable {
    case found(SymbolSpan)
    case ambiguous([SymbolSpan])
    case notFound
}

public enum SwiftSymbolLocator {

    /// Per-character classification from a single linear scan.
    enum Region {
        case code
        case lineComment
        case blockComment
        case string
    }

    /// Classify every character as code or not, so braces inside strings and
    /// comments are never counted. Handles `//`, nestable `/* */`, `"…"`,
    /// `"""…"""`, `\` escapes, and `\(…)` interpolation.
    static func maskRegions(_ source: String) -> [Region] {
        let chars = Array(source)
        var regions = [Region](repeating: .code, count: chars.count)
        var i = 0
        var blockDepth = 0
        // Stack of interpolation paren depths; when a `\(` opens inside a
        // string we resume code until the matching `)`.
        var interpolationParens: [Int] = []

        func isTripleQuote(_ at: Int) -> Bool {
            at + 2 < chars.count && chars[at] == "\"" && chars[at + 1] == "\"" && chars[at + 2] == "\""
        }

        while i < chars.count {
            let c = chars[i]

            if blockDepth > 0 {
                regions[i] = .blockComment
                if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                    regions[i + 1] = .blockComment; blockDepth += 1; i += 2; continue
                }
                if c == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                    regions[i + 1] = .blockComment; blockDepth -= 1; i += 2; continue
                }
                i += 1; continue
            }

            // Code position.
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                var j = i
                while j < chars.count && chars[j] != "\n" { regions[j] = .lineComment; j += 1 }
                i = j; continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                regions[i] = .blockComment; regions[i + 1] = .blockComment
                blockDepth = 1; i += 2; continue
            }
            if c == "\"" {
                let triple = isTripleQuote(i)
                i = scanString(chars, from: i, triple: triple, regions: &regions,
                               interpolationParens: &interpolationParens)
                continue
            }
            i += 1
        }
        return regions
    }

    /// Consume a string literal, marking its span `.string`; resume code inside
    /// `\(…)` interpolation. Returns the index just past the closing quote.
    private static func scanString(
        _ chars: [Character], from start: Int, triple: Bool,
        regions: inout [Region], interpolationParens: inout [Int]
    ) -> Int {
        var i = start
        let quoteLen = triple ? 3 : 1
        for k in 0..<quoteLen { regions[i + k] = .string }
        i += quoteLen
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                if chars[i + 1] == "(" {
                    // Interpolation: mark the backslash as string, then let
                    // the caller's main loop... but we're nested here, so we
                    // scan the balanced parens as code inline.
                    regions[i] = .string
                    regions[i + 1] = .code
                    i += 2
                    var depth = 1
                    while i < chars.count && depth > 0 {
                        if chars[i] == "(" { depth += 1 }
                        else if chars[i] == ")" { depth -= 1 }
                        regions[i] = .code
                        i += 1
                    }
                    continue
                }
                regions[i] = .string
                if i + 1 < chars.count { regions[i + 1] = .string }
                i += 2; continue
            }
            if c == "\"" {
                if triple {
                    if i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                        regions[i] = .string; regions[i + 1] = .string; regions[i + 2] = .string
                        return i + 3
                    }
                    regions[i] = .string; i += 1; continue
                }
                regions[i] = .string
                return i + 1
            }
            regions[i] = .string
            i += 1
        }
        return i
    }

    /// Locate a declaration by name.
    static func locate(symbol: String, in source: String) -> LocateResult {
        let chars = Array(source)
        let regions = maskRegions(source)

        // Header patterns over code-masked positions.
        let bracedKinds = "func|struct|class|enum|actor|protocol|extension"
        let pattern = try! NSRegularExpression(
            pattern: #"\b(\#(bracedKinds)|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let nsSource = source as NSString
        let matches = pattern.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var spans: [SymbolSpan] = []
        for match in matches {
            guard let kindRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source) else { continue }
            let name = String(source[nameRange])
            guard name == symbol else { continue }

            let kindStartOffset = source.distance(from: source.startIndex, to: kindRange.lowerBound)
            // The keyword itself must be at a code position.
            guard kindStartOffset < regions.count, isCode(regions, kindStartOffset) else { continue }

            let kind = String(source[kindRange])
            // `guard let x`, `if let x`, `for case let x` are bindings, not
            // declarations — only accept var/let when everything before it on
            // its line is attributes or declaration modifiers.
            if (kind == "var" || kind == "let")
                && !isDeclarationPosition(source, keywordStart: kindRange.lowerBound) {
                continue
            }
            let declStart = extendDeclStartUpward(source, chars: chars, from: kindRange.lowerBound)

            if let open = firstCodeBrace(source, chars: chars, regions: regions, after: nameRange.upperBound) {
                if let close = matchBrace(chars: chars, regions: regions, open: open) {
                    let openIdx = source.index(source.startIndex, offsetBy: open)
                    let endIdx = source.index(source.startIndex, offsetBy: close + 1)
                    spans.append(SymbolSpan(
                        declStart: declStart, bodyOpen: openIdx, fullEnd: endIdx,
                        kind: kind, name: name))
                    continue
                }
            }
            // Brace-less (protocol requirement, stored property): span to end of line.
            let lineEnd = source[nameRange.upperBound...].firstIndex(of: "\n") ?? source.endIndex
            spans.append(SymbolSpan(
                declStart: declStart, bodyOpen: nil, fullEnd: lineEnd,
                kind: kind, name: name))
        }

        switch spans.count {
        case 0: return .notFound
        case 1: return .found(spans[0])
        default: return .ambiguous(spans)
        }
    }

    /// The chain of declarations enclosing a character offset, outermost first (e.g.
    /// [struct SettingsSheet, var body]) — the precise "where is the cursor" answer.
    static func scopeChain(at offset: Int, in source: String) -> [SymbolSpan] {
        let chars = Array(source)
        guard offset >= 0, offset <= chars.count, !chars.isEmpty else { return [] }
        let regions = maskRegions(source)

        // All declaration headers, by the offset of their body-open brace.
        var headerByBrace: [Int: SymbolSpan] = [:]
        let pattern = try! NSRegularExpression(
            pattern: #"\b(func|struct|class|enum|actor|protocol|extension|var|let|init|subscript)\s*([A-Za-z_][A-Za-z0-9_]*)?"#)
        let nsSource = source as NSString
        for match in pattern.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) {
            guard let kindRange = Range(match.range(at: 1), in: source) else { continue }
            let kindStart = source.distance(from: source.startIndex, to: kindRange.lowerBound)
            guard kindStart < regions.count, isCode(regions, kindStart) else { continue }
            let kind = String(source[kindRange])
            var name = ""
            if match.range(at: 2).location != NSNotFound,
               let nameRange = Range(match.range(at: 2), in: source) {
                name = String(source[nameRange])
            }
            if (kind == "var" || kind == "let")
                && !isDeclarationPosition(source, keywordStart: kindRange.lowerBound) {
                continue
            }
            let afterHeader = Range(match.range, in: source)!.upperBound
            guard let open = firstCodeBrace(source, chars: chars, regions: regions, after: afterHeader),
                  headerByBrace[open] == nil else { continue }
            // The brace must belong to THIS header: nothing but signature-ish text between
            // them — no `}` at code position (a closed scope), AND no second declaration
            // keyword.
            //
            // THE SECOND HALF IS NOT DECORATION. Without it a brace-less
            // declaration reaches forward and claims the NEXT declaration's
            // body: in `let path: String` followed by `func read() {`, the
            // stored property found `read`'s opening brace, claimed it first,
            // and `read` itself was then skipped as already-claimed — so the
            // caret inside `read` reported its scope as `let path`. Measured
            // against a real file, not imagined.
            var belongs = true
            let gapStart = source.distance(from: source.startIndex, to: afterHeader)
            var i = gapStart
            while i < open {
                if chars[i] == "}" && isCode(regions, i) { belongs = false; break }
                i += 1
            }
            if belongs, gapStart < open {
                let gap = source[
                    source.index(source.startIndex, offsetBy: gapStart)
                        ..< source.index(source.startIndex, offsetBy: open)]
                belongs = !Self.namesADeclaration(in: gap)
            }
            guard belongs else { continue }
            guard let close = matchBrace(chars: chars, regions: regions, open: open) else { continue }
            let declStart = extendDeclStartUpward(source, chars: chars, from: kindRange.lowerBound)
            headerByBrace[open] = SymbolSpan(
                declStart: declStart,
                bodyOpen: source.index(source.startIndex, offsetBy: open),
                fullEnd: source.index(source.startIndex, offsetBy: close + 1),
                kind: kind,
                name: name)
        }

        // Walk braces up to `offset`, keeping the open declaration stack.
        var stack: [(brace: Int, span: SymbolSpan?)] = []
        var i = 0
        let clamped = min(offset, chars.count)
        while i < clamped {
            if isCode(regions, i) {
                if chars[i] == "{" {
                    stack.append((i, headerByBrace[i]))
                } else if chars[i] == "}" {
                    if !stack.isEmpty { stack.removeLast() }
                }
            }
            i += 1
        }
        return stack.compactMap(\.span)
    }

    // MARK: - Helpers

    private static func isCode(_ regions: [Region], _ offset: Int) -> Bool {
        if case .code = regions[offset] { return true }
        return false
    }

    /// Whether a header-to-brace gap contains a second declaration keyword —
    /// the proof that this brace opens somebody else's body.
    private static func namesADeclaration(in gap: Substring) -> Bool {
        let words = gap.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        return words.contains { declarationKeywords.contains(String($0)) }
    }

    private static let declarationKeywords: Set<String> = [
        "func", "struct", "class", "enum", "actor", "protocol", "extension",
        "init", "subscript", "deinit",
    ]

    private static let declarationModifiers: Set<String> = [
        "public", "private", "internal", "fileprivate", "open", "package",
        "static", "class", "final", "lazy", "weak", "unowned", "override",
        "nonisolated", "dynamic", "optional", "required", "indirect",
    ]

    /// True when every token before the var/let keyword on its line is an
    /// attribute or declaration modifier — i.e. this is a real declaration,
    /// not a `guard`/`if`/`while`/`for case` binding or a condition-list `let`.
    private static func isDeclarationPosition(_ source: String, keywordStart: String.Index) -> Bool {
        var lineStart = keywordStart
        while lineStart > source.startIndex {
            let prev = source.index(before: lineStart)
            if source[prev] == "\n" { break }
            lineStart = prev
        }
        let prefix = source[lineStart..<keywordStart]
        return prefix
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .allSatisfy { token in
                token.hasPrefix("@") || declarationModifiers.contains(String(token))
            }
    }

    /// Walk up across contiguous leading attribute lines (`@MainActor`, …),
    /// `///` doc comments, and access modifiers so a replacement preserves them.
    private static func extendDeclStartUpward(
        _ source: String, chars: [Character], from keywordStart: String.Index
    ) -> String.Index {
        // Back up to the start of the keyword's own line.
        var lineStart = keywordStart
        while lineStart > source.startIndex {
            let prev = source.index(before: lineStart)
            if source[prev] == "\n" { break }
            lineStart = prev
        }
        // Examine preceding lines.
        var result = lineStart
        var cursor = lineStart
        while cursor > source.startIndex {
            let prevLineEnd = source.index(before: cursor)   // the '\n'
            guard source[prevLineEnd] == "\n" else { break }
            var prevLineStart = prevLineEnd
            while prevLineStart > source.startIndex {
                let p = source.index(before: prevLineStart)
                if source[p] == "\n" { break }
                prevLineStart = p
            }
            let line = source[prevLineStart..<prevLineEnd].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@") || line.hasPrefix("///") || line.hasPrefix("//") {
                result = prevLineStart
                cursor = prevLineStart
            } else {
                break
            }
        }
        return result
    }

    private static func firstCodeBrace(
        _ source: String, chars: [Character], regions: [Region], after: String.Index
    ) -> Int? {
        var offset = source.distance(from: source.startIndex, to: after)
        while offset < chars.count {
            if chars[offset] == "{" && isCode(regions, offset) { return offset }
            // Stop at a statement terminator that means this decl has no body.
            if chars[offset] == "\n" {
                // peek: allow braces on the next line, but a `}` or top-level
                // keyword means we've overshot. Keep it simple: keep scanning.
            }
            offset += 1
        }
        return nil
    }

    private static func matchBrace(chars: [Character], regions: [Region], open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < chars.count {
            if isCode(regions, i) {
                if chars[i] == "{" { depth += 1 }
                else if chars[i] == "}" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }
}

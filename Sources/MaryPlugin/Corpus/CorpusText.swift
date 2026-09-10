//
//  CorpusText.swift
//  MaryPlugin
//
//  WHAT: Split a file into code and commentary slices, once.
//  IN:   CorpusCrawl / CorpusStyleReader
//  OUT:  code / comments / source
//  PIN:  C-family syntax (`//`, `/* */`, strings with `\(`). Blank spans, don't
//        splice. Second notation → PluginCorpusSchema.commentSyntax, not a special case.
//

import Foundation

/// One file, already split into the slices a corpus rule can ask for.
public struct CorpusText: Sendable {
    /// Outside comments and strings, those spans blanked (not removed) so tokens stay apart.
    public let code: String
    /// Only commentary, same treatment in reverse.
    public let comments: String
    public let source: String
    public let filename: String
    public let byteCount: Int

    public init(source: String, filename: String) {
        self.source = source
        self.filename = filename
        self.byteCount = source.utf8.count
        let regions = CFamilyRegions.mask(source)
        let characters = Array(source)
        var codeOnly = String()
        var commentsOnly = String()
        codeOnly.reserveCapacity(characters.count)
        commentsOnly.reserveCapacity(characters.count / 4)
        for (index, character) in characters.enumerated() {
            // Newlines survive into both slices (line-anchored patterns).
            let isNewline = character == "\n"
            switch regions[index] {
            case .code:
                codeOnly.append(character)
                if isNewline { commentsOnly.append(character) }
            case .lineComment, .blockComment:
                commentsOnly.append(character)
                if isNewline { codeOnly.append(character) }
            case .string:
                // A string is neither code nor commentary.
                if isNewline {
                    codeOnly.append(character)
                    commentsOnly.append(character)
                }
            }
        }
        self.code = codeOnly
        self.comments = commentsOnly
    }

    public func slice(_ region: PluginCorpusRegion) -> String {
        switch region {
        case .code: return code
        case .comments: return comments
        case .source: return source
        case .filename: return filename
        }
    }
}

/// Lexical mask: which characters are code, commentary, or string.
public enum CFamilyRegions {

    public enum Region: Sendable {
        case code
        case lineComment
        case blockComment
        case string
    }

    /// Nested block comments counted, not merely matched.
    public static func mask(_ source: String) -> [Region] {
        let characters = Array(source)
        var regions = [Region](repeating: .code, count: characters.count)
        var index = 0
        var blockDepth = 0
        /// Paren depths at which a `\(` interpolation opened — inside, content is code again.
        var interpolationParens: [Int] = []
        var parenDepth = 0

        func isTripleQuote(_ at: Int) -> Bool {
            at + 2 < characters.count
                && characters[at] == "\"" && characters[at + 1] == "\""
                && characters[at + 2] == "\""
        }

        while index < characters.count {
            let character = characters[index]

            if blockDepth > 0 {
                regions[index] = .blockComment
                if character == "/", index + 1 < characters.count,
                   characters[index + 1] == "*" {
                    regions[index + 1] = .blockComment
                    blockDepth += 1
                    index += 2
                    continue
                }
                if character == "*", index + 1 < characters.count,
                   characters[index + 1] == "/" {
                    regions[index + 1] = .blockComment
                    blockDepth -= 1
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                var scan = index
                while scan < characters.count, characters[scan] != "\n" {
                    regions[scan] = .lineComment
                    scan += 1
                }
                index = scan
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                regions[index] = .blockComment
                regions[index + 1] = .blockComment
                blockDepth = 1
                index += 2
                continue
            }
            if character == "\"" {
                index = scanString(
                    characters, from: index, triple: isTripleQuote(index),
                    regions: &regions, interpolationParens: &interpolationParens,
                    parenDepth: &parenDepth)
                continue
            }
            index += 1
        }
        return regions
    }

    /// Consume a string literal; resume code inside `\(`…`)`. Returns index past the close.
    private static func scanString(
        _ characters: [Character],
        from start: Int,
        triple: Bool,
        regions: inout [Region],
        interpolationParens: inout [Int],
        parenDepth: inout Int
    ) -> Int {
        var index = start
        let quoteLength = triple ? 3 : 1
        for offset in 0..<quoteLength where index + offset < characters.count {
            regions[index + offset] = .string
        }
        index += quoteLength

        while index < characters.count {
            let character = characters[index]

            // Escaped character is part of the literal, including an escaped quote.
            if character == "\\", index + 1 < characters.count {
                if characters[index + 1] == "(" {
                    regions[index] = .string
                    regions[index + 1] = .string
                    parenDepth += 1
                    interpolationParens.append(parenDepth)
                    index += 2
                    // Code resumes until the matching paren closes.
                    while index < characters.count, !interpolationParens.isEmpty {
                        let inner = characters[index]
                        if inner == "(" { parenDepth += 1 }
                        if inner == ")" {
                            if interpolationParens.last == parenDepth {
                                interpolationParens.removeLast()
                                regions[index] = .string
                            }
                            parenDepth -= 1
                        }
                        index += 1
                    }
                    continue
                }
                regions[index] = .string
                regions[index + 1] = .string
                index += 2
                continue
            }

            if character == "\"" {
                if triple {
                    if index + 2 < characters.count,
                       characters[index + 1] == "\"", characters[index + 2] == "\"" {
                        regions[index] = .string
                        regions[index + 1] = .string
                        regions[index + 2] = .string
                        return index + 3
                    }
                } else {
                    regions[index] = .string
                    return index + 1
                }
            }

            // Unterminated single-quoted string ends at the line.
            if character == "\n", !triple {
                return index
            }

            regions[index] = .string
            index += 1
        }
        return index
    }
}

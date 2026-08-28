//
//  CorpusText.swift
//  MaryAdapters
//
//  SPLITTING A FILE INTO CODE AND COMMENTARY, once, so every rule that runs
//  over it reads the slice it asked for.
//
//  WHY THE SPLIT IS NOT OPTIONAL. A rule counting `throws` must not match the
//  word inside a comment explaining why something does not throw, and the
//  comment-posture rules must read ONLY comments or they end up measuring the
//  code. Both mistakes produce numbers rather than errors, and a number is
//  believed.
//
//  ONCE PER FILE, THREADED THROUGH. The observer this replaces recomputed the
//  mask inside whichever detector wanted it — roughly four full passes per
//  file, each allocating a character array the size of the source, for one
//  file's worth of answers. The slices here are computed together and handed
//  to every rule.
//
//  THE HONEST LIMIT: THIS IS C-FAMILY SYNTAX. `//`, `/* */`, double-quoted
//  strings with `\(…)` interpolation. That is correct for the one notation
//  that declares a corpus today and wrong for a notation whose comments look
//  different — a Markdown corpus has no comments at all, and a chapter's
//  annotations are not lexical. It is named for what it is rather than called
//  generic, and the day a second notation needs different rules the answer is
//  a `commentSyntax` block in `PluginCorpusSchema` beside the ones already
//  there, not a special case in here.
//

import Foundation

/// One file, already split into the slices a corpus rule can ask for.
public struct CorpusText: Sendable {
    /// Everything outside comments and string literals, with those spans
    /// blanked rather than removed — so a pattern cannot accidentally join two
    /// tokens that had a comment between them.
    public let code: String
    /// Only the commentary, same treatment in reverse.
    public let comments: String
    /// The file as it was read.
    public let source: String
    /// The file's own last path component.
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
            // NEWLINES SURVIVE INTO BOTH SLICES. A line-anchored pattern —
            // the comment-density counter is one — needs the line structure
            // of the file it is measuring, and blanking a newline would join
            // every commented line into one.
            let isNewline = character == "\n"
            switch regions[index] {
            case .code:
                codeOnly.append(character)
                if isNewline { commentsOnly.append(character) }
            case .lineComment, .blockComment:
                commentsOnly.append(character)
                if isNewline { codeOnly.append(character) }
            case .string:
                // A STRING IS NEITHER. Its contents are data the author
                // happened to type; counting `guard` inside an error message
                // as a binding style is how a file votes for a habit it does
                // not have.
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

/// The lexical mask: which characters are code, commentary or string.
public enum CFamilyRegions {

    public enum Region: Sendable {
        case code
        case lineComment
        case blockComment
        case string
    }

    /// Nested block comments are counted, not merely matched — the language
    /// this was written for allows them, and treating `/* /* */ */` as closed
    /// at the first `*/` would spill a comment's tail into the code slice.
    public static func mask(_ source: String) -> [Region] {
        let characters = Array(source)
        var regions = [Region](repeating: .code, count: characters.count)
        var index = 0
        var blockDepth = 0
        /// Paren depths at which a `\(` interpolation opened: inside one, the
        /// content is code again until the matching `)`.
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

    /// Consume a string literal, marking its span, resuming code inside
    /// `\(…)`. Returns the index just past the closing quote.
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

            // An escaped character is part of the literal, whatever it is —
            // including an escaped quote, which must not end the string.
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

            // AN UNTERMINATED SINGLE-QUOTED STRING ENDS AT THE LINE. Without
            // this a stray quote in one line swallows the rest of the file
            // into the string slice, and every rule below it goes quiet.
            if character == "\n", !triple {
                return index
            }

            regions[index] = .string
            index += 1
        }
        return index
    }
}

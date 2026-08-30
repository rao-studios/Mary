//
//  CodeSurfaceEdit.swift
//  MaryPlugin
//
//  Pure text-editing math over a live buffer. Every mutation computes the
//  NEW whole-file text in Swift; the writer then puts that text on disk.
//  Nothing here names an application — the locator for `notation: swift` is
//  `SwiftSymbolLocator`; other notations fall through to unique-snippet
//  replace.
//

import Foundation

public struct CodeSurfaceEditResult: Equatable {
    public var newText: String
    public var summary: String
}

public enum CodeSurfaceEditError: LocalizedError {
    case symbolNotFound(String)
    case symbolAmbiguous(String, count: Int)
    case noMatch(String)
    case multipleMatches(String, count: Int)
    case selectionMissing

    public var errorDescription: String? {
        switch self {
        case .symbolNotFound(let name):
            return "I don't see \(name) in this file."
        case .symbolAmbiguous(let name, let count):
            return "There are \(count) things called \(name) — tell me which, or I can add a new one."
        case .noMatch(let find):
            return "I couldn't find \"\(find.prefix(40))\" to change."
        case .multipleMatches(let find, let count):
            return "\"\(find.prefix(40))\" appears \(count) times — be more specific so I change the right one."
        case .selectionMissing:
            return "Nothing is selected."
        }
    }
}

public enum CodeSurfaceEdit {

    public static func replaceSymbol(
        _ name: String, with newSource: String, in text: String
    ) throws -> CodeSurfaceEditResult {
        switch SwiftSymbolLocator.locate(symbol: name, in: text) {
        case .notFound:
            throw CodeSurfaceEditError.symbolNotFound(name)
        case .ambiguous(let spans):
            throw CodeSurfaceEditError.symbolAmbiguous(name, count: spans.count)
        case .found(let span):
            let trimmed = newSource.trimmingCharacters(in: .newlines)
            var newText = text
            newText.replaceSubrange(span.declStart..<span.fullEnd, with: trimmed)
            return CodeSurfaceEditResult(
                newText: newText, summary: "replaced \(span.kind) \(name)")
        }
    }

    public static func insertCode(
        _ source: String, afterSymbol name: String?, in text: String
    ) throws -> CodeSurfaceEditResult {
        let block = source.trimmingCharacters(in: .newlines)
        if let name, !name.isEmpty {
            switch SwiftSymbolLocator.locate(symbol: name, in: text) {
            case .notFound:
                throw CodeSurfaceEditError.symbolNotFound(name)
            case .ambiguous(let spans):
                throw CodeSurfaceEditError.symbolAmbiguous(name, count: spans.count)
            case .found(let span):
                var newText = text
                newText.insert(contentsOf: "\n\n" + block, at: span.fullEnd)
                return CodeSurfaceEditResult(
                    newText: newText, summary: "added code after \(name)")
            }
        }
        let separator = text.hasSuffix("\n") ? "\n" : "\n\n"
        return CodeSurfaceEditResult(
            newText: text + separator + block + "\n",
            summary: "added code at the end of the file")
    }

    public static func applyEdit(
        find: String, replace: String, in text: String
    ) throws -> CodeSurfaceEditResult {
        guard !find.isEmpty else { throw CodeSurfaceEditError.noMatch(find) }
        var occurrences = 0
        var searchStart = text.startIndex
        var firstRange: Range<String.Index>?
        while let range = text.range(of: find, range: searchStart..<text.endIndex) {
            occurrences += 1
            if firstRange == nil { firstRange = range }
            searchStart = range.upperBound
        }
        guard occurrences > 0 else { throw CodeSurfaceEditError.noMatch(find) }
        guard occurrences == 1, let range = firstRange else {
            throw CodeSurfaceEditError.multipleMatches(find, count: occurrences)
        }
        var newText = text
        newText.replaceSubrange(range, with: replace)
        return CodeSurfaceEditResult(newText: newText, summary: "made the change")
    }
}

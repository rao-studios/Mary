//
//  CodingAgentWorkspace.swift
//  MaryPlugin
//
//  WHAT: File tools jailed to one authorized project root.
//  IN:   CodingAgentBackend / ProjectRootResolver
//  OUT:  CodingAgentAuthorship (for CorpusObserver style gate)
//  PIN:  Conversation model never sees these; only the coding-agent engine does.
//

import Foundation
import MaryFoundation
import os

public enum CodingAgentWorkspace {

    public static let toolSchemas: [ModelSkillSchema] = [
        ModelSkillSchema(
            name: "read_file",
            description: "Read a UTF-8 file inside the authorized project root.",
            parameters: [
                .init(name: "path", type: "string",
                      description: "Path relative to the project root, or absolute under it.",
                      required: true),
                .init(name: "offset", type: "integer",
                      description: "1-based start line. Omit to read from the start.",
                      required: false),
                .init(name: "limit", type: "integer",
                      description: "Maximum lines to return.",
                      required: false),
            ]),
        ModelSkillSchema(
            name: "list_dir",
            description: "List files and folders inside the authorized project root.",
            parameters: [
                .init(name: "path", type: "string",
                      description: "Directory relative to the project root. Omit for the root.",
                      required: false),
            ]),
        ModelSkillSchema(
            name: "grep",
            description: "Search file contents under the authorized project root.",
            parameters: [
                .init(name: "pattern", type: "string",
                      description: "Regular expression to find.",
                      required: true),
                .init(name: "path", type: "string",
                      description: "File or directory to search. Omit for the whole root.",
                      required: false),
            ]),
        ModelSkillSchema(
            name: "write_file",
            description: "Create or replace a UTF-8 file inside the authorized project root.",
            parameters: [
                .init(name: "path", type: "string",
                      description: "Path relative to the project root.",
                      required: true),
                .init(name: "contents", type: "string",
                      description: "Full new file contents.",
                      required: true),
            ]),
        ModelSkillSchema(
            name: "apply_patch",
            description: "Apply a search/replace or begin-patch edit inside the authorized project root.",
            parameters: [
                .init(name: "path", type: "string",
                      description: "File to patch, relative to the project root.",
                      required: true),
                .init(name: "patch", type: "string",
                      description: "A *** Begin Patch block, or <<<<<<< SEARCH / ======= / >>>>>>> REPLACE hunks.",
                      required: true),
            ]),
    ]

    public static func resolve(_ raw: String, workdir: String) throws -> URL {
        let root = URL(fileURLWithPath: workdir).standardizedFileURL
        let candidate: URL
        if raw.hasPrefix("/") {
            candidate = URL(fileURLWithPath: raw).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(raw).standardizedFileURL
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let candPath = candidate.path
        guard candPath == root.path || candPath.hasPrefix(rootPath) else {
            throw CodingAgentBackendError.failed(
                "That path is outside the authorized project root.")
        }
        return candidate
    }

    public static func perform(
        name: String, arguments: [String: String], workdir: String
    ) throws -> String {
        switch name {
        case "read_file":
            guard let path = arguments["path"], !path.isEmpty else {
                throw CodingAgentBackendError.failed("Which file?")
            }
            let url = try resolve(path, workdir: workdir)
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let offset = max(1, Int(arguments["offset"] ?? "1") ?? 1)
            let limit = Int(arguments["limit"] ?? "") ?? lines.count
            let slice = lines.dropFirst(offset - 1).prefix(limit)
            return slice.enumerated().map { "\(offset + $0.offset):\($0.element)" }
                .joined(separator: "\n")
        case "list_dir":
            let url = try resolve(arguments["path"] ?? ".", workdir: workdir)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { !$0.hasPrefix(".") }
                .sorted()
            return names.isEmpty ? "(empty)" : names.joined(separator: "\n")
        case "grep":
            guard let pattern = arguments["pattern"], !pattern.isEmpty else {
                throw CodingAgentBackendError.failed("What should I search for?")
            }
            let regex = try NSRegularExpression(pattern: pattern)
            let start = try resolve(arguments["path"] ?? ".", workdir: workdir)
            var hits: [String] = []
            try walk(start, workdir: workdir) { file in
                guard hits.count < 80 else { return }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
                let ns = text as NSString
                let matches = regex.matches(
                    in: text, range: NSRange(location: 0, length: ns.length))
                guard !matches.isEmpty else { return }
                let rel = relative(file, workdir: workdir)
                for match in matches.prefix(8) {
                    let line = ns.substring(with: match.range)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    hits.append("\(rel): \(line.prefix(200))")
                }
            }
            return hits.isEmpty ? "No matches." : hits.joined(separator: "\n")
        case "write_file":
            guard let path = arguments["path"], !path.isEmpty else {
                throw CodingAgentBackendError.failed("Which file?")
            }
            let url = try resolve(path, workdir: workdir)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try (arguments["contents"] ?? "").write(to: url, atomically: true, encoding: .utf8)
            CodingAgentAuthorship.noteWrite(at: url)
            return "Wrote \(relative(url, workdir: workdir))."
        case "apply_patch":
            guard let path = arguments["path"], !path.isEmpty else {
                throw CodingAgentBackendError.failed("Which file?")
            }
            let url = try resolve(path, workdir: workdir)
            let original = try String(contentsOf: url, encoding: .utf8)
            let patched = try apply(patch: arguments["patch"] ?? "", to: original)
            try patched.write(to: url, atomically: true, encoding: .utf8)
            CodingAgentAuthorship.noteWrite(at: url)
            return "Patched \(relative(url, workdir: workdir))."
        default:
            throw CodingAgentBackendError.failed("Unknown coding tool \(name).")
        }
    }

    /// Pull a fenced begin-patch / search-replace block out of model prose.
    public static func extractPatchFence(from text: String) -> (path: String, patch: String)? {
        if let begin = text.range(of: "*** Begin Patch"),
           let end = text.range(of: "*** End Patch") {
            let body = String(text[begin.lowerBound..<end.upperBound])
            var path = ""
            if let fileLine = body.split(separator: "\n").first(where: {
                $0.contains("Update File:") || $0.contains("Add File:")
            }) {
                if let colon = fileLine.range(of: ":") {
                    path = fileLine[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                }
            }
            return path.isEmpty ? nil : (path, body)
        }
        if text.contains("<<<<<<< SEARCH") { return nil }
        return nil
    }

    static func apply(patch: String, to original: String) throws -> String {
        if let search = patch.range(of: "<<<<<<< SEARCH"),
           let mid = patch.range(of: "======="),
           let end = patch.range(of: ">>>>>>> REPLACE") {
            let find = String(patch[search.upperBound..<mid.lowerBound])
                .trimmingCharacters(in: .newlines)
            let replace = String(patch[mid.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .newlines)
            guard original.contains(find) else {
                throw CodingAgentBackendError.failed("The search text was not in that file.")
            }
            return original.replacingOccurrences(of: find, with: replace)
        }
        // Minimal *** Update File hunk: '-' then '+' after context.
        var result = original
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var removals: [String] = []
        var additions: [String] = []
        for line in lines {
            if line.hasPrefix("-"), !line.hasPrefix("---") {
                removals.append(String(line.dropFirst()))
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                additions.append(String(line.dropFirst()))
            }
        }
        if !removals.isEmpty {
            let find = removals.joined(separator: "\n")
            guard result.contains(find) else {
                throw CodingAgentBackendError.failed("The patch context was not in that file.")
            }
            result = result.replacingOccurrences(of: find, with: additions.joined(separator: "\n"))
            return result
        }
        if !additions.isEmpty {
            return original + (original.hasSuffix("\n") ? "" : "\n") + additions.joined(separator: "\n")
        }
        throw CodingAgentBackendError.failed("I could not read that patch.")
    }

    private static func walk(
        _ url: URL, workdir: String, visit: (URL) throws -> Void
    ) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if !isDir.boolValue {
            try visit(url)
            return
        }
        let skip: Set<String> = [".git", ".build", "node_modules", "DerivedData", ".swiftpm"]
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL {
            if skip.contains(file.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            try visit(file)
        }
    }

    private static func relative(_ url: URL, workdir: String) -> String {
        let root = URL(fileURLWithPath: workdir).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
        }
        return url.lastPathComponent
    }
}

/// Paths the on-device coding agent wrote this session.
/// OUT: CorpusObserver — do not treat those mtimes as the user's hand.
public enum CodingAgentAuthorship {
    private static let box = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    public static func noteWrite(at url: URL) {
        let path = url.standardizedFileURL.path
        box.withLock { _ = $0.insert(path) }
    }

    public static func contains(_ absolutePath: String) -> Bool {
        let path = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        return box.withLock { $0.contains(path) }
    }

    /// Test seam.
    public static func reset() {
        box.withLock { $0 = [] }
    }
}

//
//  ApplicationNameTests.swift
//  MaryFoundationTests
//
//  NO APPLICATION IS NAMED IN MARY'S CODE. Not in a switch, not in a string
//  table, not in a Skill description the model reads.
//
//  THIS IS THE LOCKED DECISION MADE MECHANICAL. Every application Mary can
//  reach arrives as a declaration — a `.mary` package saying what it is
//  called, what its documents are called, which roles hold its text, which
//  chord makes a new one. The moment a product name appears in Swift, one
//  application is special: it works without a package, it survives a package
//  being uninstalled, and the next application gets whatever behaviour the
//  first one's name happened to be wired to.
//
//  THE FAILURES THIS CATCHES ARE REAL AND WERE FOUND BY HAND. A window
//  classifier took two booleans named after one editor, so "the note" was a
//  phrase compiled into Mary and a place calling its documents chapters got
//  nothing. A Skill description told the model to pass "pages, textedit, or
//  scrivener" — a capability claim about three applications that may not be
//  installed. A cue-word list carried product names, so naming your editor
//  worked only if it was one of five.
//
//  COMMENTS ARE EXEMT, and deliberately: a comment naming the application a
//  bug was observed in is the most useful sentence in the file. What is banned
//  is a name the code READS.
//
//  THE ALLOWLIST IS SHORT AND EACH ENTRY EARNS ITS PLACE — see `allowed`.
//

import Foundation
import Testing

@Suite struct ApplicationNameTests {

    /// Product names that are ONLY product names. Matched anywhere in a line
    /// of code, case-insensitively, because there is no innocent reading.
    static let banned = [
        "textedit", "scrivener", "keynote", "xcode", "sketch", "safari",
    ]

    /// The one innocent reading there turned out to be.
    ///
    /// SwiftUI ships `TextEditor`, and a multi-line text field is not an
    /// application. "There is no innocent reading" was true of every name on
    /// the list until a view layer arrived that had its own claim on one of
    /// them — Ability Studio, whose editors are full of `TextEditor` and local
    /// `textEditor` properties. Five honest lines tripped the gate at once.
    ///
    /// EXEMPTED BY SHAPE, NOT BY FILE. Adding those files to `allowed` would
    /// have switched the whole gate off for them, including the names that
    /// would be real offences; this exempts exactly `TextEditor` and nothing
    /// else, so `TextEditPlugin` — a name Mary must never carry — still trips.
    /// A gate that cries wolf gets switched off; the fix is to make it stop
    /// crying, precisely.
    static let innocent = [#"textedit(?=or\b)"#]

    /// Product names that are ALSO ordinary English — "pages", "notes",
    /// "reminders", "chrome" — matched only where they read as an identifier
    /// or a token rather than as a word.
    ///
    /// A GATE THAT CRIES WOLF GETS SWITCHED OFF. Banning the bare word would
    /// flag "the document's pages", "chrome plating" and every reminder the
    /// calendar lane has ever spoken about; within a week somebody adds the
    /// file to the allowlist and the rule stops protecting anything. Requiring
    /// identifier shape keeps the two real cases — `.pages`, `"pages"` — and
    /// drops the prose.
    static let bannedAsTokens = ["pages", "notes", "reminders", "chrome"]

    /// The shapes that make an ordinary word a product reference: the whole
    /// word, delimited, after a dot or inside quotes or a hyphenated token.
    ///
    /// THE DELIMITER IS THE WHOLE TRICK. `.notes` without one matches
    /// `noteSurface`, `noteSkillResult` and every other place the VERB "note"
    /// begins an identifier — which is most of the trace layer.
    static func namesProduct(_ line: String, _ name: String) -> Bool {
        let pattern = "(?:\\.|\"|-|_)\(name)(?![A-Za-z0-9])"
        return line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// An unambiguous product name, minus the one shape that is not one.
    ///
    /// `line` arrives already lowercased. Every occurrence must be innocent
    /// for the line to pass — a line carrying both `TextEditor` and a real
    /// `textedit` still offends, which is why this counts rather than
    /// short-circuits.
    static func namesApplication(_ line: String, _ name: String) -> Bool {
        var searchRange = line.startIndex..<line.endIndex
        while let found = line.range(of: name, range: searchRange) {
            let isInnocent = Self.innocent.contains { pattern in
                line.range(
                    of: pattern,
                    options: [.regularExpression],
                    range: found.lowerBound..<line.endIndex)?.lowerBound == found.lowerBound
            }
            if !isInnocent { return true }
            searchRange = found.upperBound..<line.endIndex
        }
        return false
    }

    /// Files where naming an application is the honest thing to do.
    ///
    /// EACH ENTRY IS A REASON, not a convenience:
    ///
    /// - `WorkspaceApplicationIdentity` is a table of BUNDLE IDENTIFIERS, which
    ///   are facts about macOS rather than about Mary. A package supplies its
    ///   own; these are the handful the ambient layer needs before any package
    ///   has loaded.
    /// - `WebContentHost` classifies a browser ENGINE FAMILY (WebKit versus
    ///   Chromium) from bundle prefixes. The distinction is real, structural,
    ///   and not something a package can declare about somebody else's browser.
    /// - Test fixtures and probes name concrete things on purpose: a fixture
    ///   with no name tests nothing, and a probe drives a real application.
    static let allowed = [
        "WorkspaceApplicationIdentity.swift",
        "WebContentHost.swift",
    ]

    /// Directories exempt wholesale: fixtures, probes, and this file.
    static let allowedDirectories = ["Tests/", "Sources/Probes/", "TestSupport/"]

    /// THE EXEMPTION IS EXACTLY ONE SHAPE WIDE.
    ///
    /// Loosening a doctrine gate without pinning what it still catches is how
    /// a gate quietly becomes decoration. `TextEditor` is SwiftUI's; every
    /// other spelling that contains those letters is the application, and must
    /// still offend — including `TextEditPlugin`, which is the exact name Mary
    /// exists not to have.
    @Test(arguments: [
        ("TextEditor(text: $text)", false),
        ("var textEditor: some View {", false),
        ("private let editor = TextEditor(text: binding)", false),
        ("struct TextEditPlugin: MaryAdapter {", true),
        ("case textedit", true),
        ("\"com.apple.TextEdit\"", true),
        ("bundleIdentifiers: [\"com.apple.TextEdit\"]", true),
        // BOTH ON ONE LINE: the innocent occurrence must not excuse the guilty
        // one, which is why the scan counts occurrences instead of stopping at
        // the first thing it can forgive.
        ("TextEditor(text: bindingFor(.textedit))", true),
    ])
    func onlySwiftUIsTextEditorIsInnocent(_ line: String, _ offends: Bool) {
        #expect(Self.namesApplication(line.lowercased(), "textedit") == offends)
    }

    @Test func noApplicationIsNamedInCode() throws {
        var offences: [String] = []
        for file in try Self.swiftFiles() {
            let path = file.path
            if Self.allowedDirectories.contains(where: path.contains) { continue }
            if Self.allowed.contains(file.lastPathComponent) { continue }

            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in Self.codeLines(of: source) {
                let lower = line.lowercased()
                for name in Self.banned
                where Self.namesApplication(lower, name) {
                    offences.append(
                        "\(file.lastPathComponent):\(number) names \(name) — \(line.trimmed)")
                }
                for name in Self.bannedAsTokens
                where Self.namesProduct(line, name) {
                    offences.append(
                        "\(file.lastPathComponent):\(number) names \(name) — \(line.trimmed)")
                }
            }
        }
        #expect(offences.isEmpty, """
            Mary's code names \(offences.count) application(s). Every application \
            arrives as a declaration; a name in Swift makes one of them special.

            \(offences.prefix(12).joined(separator: "\n"))
            """)
    }

    /// THE GATE HAS TEETH — pinned against a planted line, because a scanner
    /// that silently matches nothing passes every audit it will ever face.
    @Test func theGateCatchesAPlantedName() {
        let planted = """
            let editors = ["textedit"]
            let ordinary = "count the pages in the chapter"
            let token = editors.first == "pages"
            """
        let hits = Self.codeLines(of: planted).filter { _, line in
            let lower = line.lowercased()
            return Self.banned.contains(where: lower.contains)
                || Self.bannedAsTokens.contains { Self.namesProduct(line, $0) }
        }
        // The product name and the quoted token are caught; the sentence
        // about a chapter's pages is not.
        #expect(hits.count == 2, "caught: \(hits.map(\.1))")
    }

    /// AND EXEMPTS COMMENTS, pinned the same way.
    @Test func theGateIgnoresAComment() {
        let commented = """
            // Observed live in TextEdit: five windows all called Untitled.
            /// Pages partitions its text by page, which is why this lane stops there.
            let cap = 500_000
            """
        let hits = Self.codeLines(of: commented).filter { _, line in
            Self.banned.contains(where: line.lowercased().contains)
        }
        #expect(hits.isEmpty)
    }

    // MARK: - The same doctrine, in data

    /// A PACKAGE MAY NAME ITSELF, AND NOTHING ELSE.
    ///
    /// The Swift rule above has an exact counterpart in the shipped packages,
    /// and the same failure. A DISCIPLINE package listed three editors in
    /// `ability.applications`, so those three were the writing applications
    /// and every editor installed afterwards was not, whatever its own
    /// package said about itself. `window-management` carried one
    /// application's window class through its capability constraints, its
    /// skills' target classes and a routing exclusion — so its Skills were
    /// eligible for that application's windows and nobody else's. And a
    /// model-facing parameter offered a closed `enumValues` list of four
    /// products, teaching the model that anything unlisted was not an option.
    ///
    /// None of that is catchable by reading Swift, and all of it has exactly
    /// the effect the Swift rule exists to prevent.
    @Test func noPackageNamesAnApplicationOtherThanItsOwn() throws {
        let abilities = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Abilities", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: abilities, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "mary" }.sorted { $0.path < $1.path } ?? []
        guard !files.isEmpty else {
            print("[packages] PENDING (no .mary packages yet): \(#function)")
            return
        }

        var offences: [String] = []
        for file in files {
            // ITS OWN NAME IS THE ONE IT MAY SAY. `textedit.mary` IS the
            // declaration of that application; forbidding it there would
            // forbid the file from existing.
            let own = file.deletingPathExtension().lastPathComponent.lowercased()
            let data = try Data(contentsOf: file)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                offences.append("\(file.lastPathComponent) is not an object")
                continue
            }
            // THE IDENTIFYING FIELDS ONLY. A whole-file scan flags a package
            // for calling its documents "notes", which is the word for its
            // documents and exactly what `documentNoun` is for. These four
            // keys are where a package says WHICH APPLICATION something is.
            for (path, value) in Self.identifyingStrings(root) {
                let text = value.lowercased()
                for name in (Self.banned + Self.bannedAsTokens) where name != own {
                    guard text.contains(name) else { continue }
                    offences.append(
                        "\(file.lastPathComponent) names \(name) at \(path): \"\(value)\"")
                }
            }
        }
        #expect(offences.isEmpty, """
            \(offences.count) package(s) name an application that is not their own:

            \(offences.joined(separator: "\n"))
            """)
    }

    /// Keys whose values IDENTIFY an application rather than describe one.
    static let identifyingKeys: Set<String> = [
        "aliases", "bundleIdentifiers", "bundleNames", "targetClasses",
        "enumValues", "applications", "allowedTargetClass",
    ]

    /// Every string under an identifying key, with the path that reached it.
    static func identifyingStrings(
        _ node: Any, path: String = "", inside: Bool = false
    ) -> [(String, String)] {
        switch node {
        case let text as String:
            return inside ? [(path, text)] : []
        case let array as [Any]:
            return array.enumerated().flatMap {
                identifyingStrings($1, path: "\(path)[\($0)]", inside: inside)
            }
        case let object as [String: Any]:
            return object.sorted { $0.key < $1.key }.flatMap { key, value in
                identifyingStrings(
                    value,
                    path: path.isEmpty ? key : "\(path).\(key)",
                    inside: inside || identifyingKeys.contains(key))
            }
        default:
            return []
        }
    }

    // MARK: - Scanning

    /// Every line with its comment tail removed, block comments dropped.
    static func codeLines(of source: String) -> [(Int, String)] {
        var rows: [(Int, String)] = []
        var inBlock = false
        for (index, raw) in source.split(
            separator: "\n", omittingEmptySubsequences: false).enumerated()
        {
            var line = String(raw)
            if inBlock {
                guard let close = line.range(of: "*/") else { continue }
                inBlock = false
                line = String(line[close.upperBound...])
            }
            if let open = line.range(of: "/*") {
                let head = String(line[..<open.lowerBound])
                inBlock = line.range(of: "*/", range: open.upperBound..<line.endIndex) == nil
                line = head
            }
            if let comment = line.range(of: "//") {
                line = String(line[..<comment.lowerBound])
            }
            guard !line.trimmed.isEmpty else { continue }
            rows.append((index + 1, line))
        }
        return rows
    }

    static func swiftFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        else { throw CocoaError(.fileNoSuchFile) }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

//
//  BrandTokenTests.swift
//  MaryFoundationTests
//
//  MARY IS NOT BONNIE WEARING A NEW LABEL.
//
//  Most of this package is ported from Bonnie, and a rename sweep across
//  ~58,000 lines does not fail loudly — it fails in the places a compiler
//  never looks. A missed type name breaks the build and is fixed in seconds.
//  A missed STRING LITERAL does not: a persistence key still reading
//  `bonnie.persistence.chat.0001`, a pid directory under Application Support/
//  Bonnie, a resource bundle named Bonnie_BonnieVoice.bundle, a UTI of
//  nyc.rao.bonnie.ability-package. Each of those compiles, ships, and then
//  quietly collides with the other app on the same machine — reading its
//  conversation store, adopting its server processes, or claiming its
//  documents.
//
//  So the gate is: no `bonnie` token in CODE anywhere under Sources/, in the
//  manifest, in the bundle plist, or in a shipped Plugin package. Comments are
//  exempt and deliberately so — porting notes that say where a file came from
//  and which Bonnie bug shaped it are worth keeping, and they are the only
//  honest place for that provenance to live.
//

import Foundation
import Testing

@Suite struct BrandTokenTests {

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaryFoundationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Source text with `//` line comments and `/* … */` block comments
    /// removed, newlines preserved so a reported line number still means
    /// something.
    ///
    /// Not a Swift parser: a `//` inside a string literal (a URL, say) trims
    /// the rest of that line. That is the safe direction — it can only make
    /// the gate blind to a token it would otherwise catch on a line that
    /// already contains a URL, never make it flag correct code.
    static func stripComments(_ source: String) -> String {
        var output = ""
        var inBlockComment = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var kept = ""
            var index = line.startIndex
            while index < line.endIndex {
                let rest = line[index...]
                if inBlockComment {
                    if let close = rest.range(of: "*/") {
                        inBlockComment = false
                        index = close.upperBound
                    } else {
                        index = line.endIndex
                    }
                    continue
                }
                if rest.hasPrefix("//") { break }
                if rest.hasPrefix("/*") {
                    inBlockComment = true
                    index = line.index(index, offsetBy: 2)
                    continue
                }
                kept.append(line[index])
                index = line.index(after: index)
            }
            output.append(kept)
            output.append("\n")
        }
        return output
    }

    /// Every file under `directory` whose extension is in `extensions`.
    static func files(under directory: URL, extensions: Set<String>) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { extensions.contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
    }

    /// Lines of `text` containing `bonnie` in any casing, as "42: the line".
    static func offendingLines(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.element.range(of: "bonnie", options: .caseInsensitive) != nil }
            .map { "\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
    }

    /// NO `bonnie` TOKEN IN SHIPPED SWIFT CODE.
    @Test func sourcesCarryNoBrandTokenOutsideComments() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        guard FileManager.default.fileExists(atPath: sources.path) else { return }

        var offenders: [String] = []
        for file in Self.files(under: sources, extensions: ["swift"]) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = Self.offendingLines(in: Self.stripComments(text))
            guard !lines.isEmpty else { continue }
            let relative = file.path.replacingOccurrences(of: sources.path + "/", with: "")
            offenders.append("\(relative)\n    " + lines.joined(separator: "\n    "))
        }

        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) file(s) under Sources/ carry a `bonnie` token in code. \
            Comments are exempt; identifiers and string literals are not — a missed \
            literal is how two apps end up sharing one store.

            \(offenders.joined(separator: "\n\n"))
            """)
    }

    /// NO `bonnie` TOKEN IN THE MANIFEST, THE BUNDLE PLIST, OR A SHIPPED
    /// PLUGIN PACKAGE. Same reasoning, different file types: the plist carries
    /// the bundle id and the exported UTI, and a Plugin package carries the
    /// format string every reader keys on.
    @Test func manifestPlistAndPackagesCarryNoBrandToken() throws {
        var offenders: [String] = []

        let manifest = Self.repositoryRoot.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let text = try String(contentsOf: manifest, encoding: .utf8)
            let lines = Self.offendingLines(in: Self.stripComments(text))
            if !lines.isEmpty { offenders.append("Package.swift\n    " + lines.joined(separator: "\n    ")) }
        }

        for directory in ["Support", "Abilities"] {
            let root = Self.repositoryRoot.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for file in Self.files(under: root, extensions: ["plist", "mary", "json"]) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let lines = Self.offendingLines(in: text)
                guard !lines.isEmpty else { continue }
                offenders.append(
                    "\(directory)/\(file.lastPathComponent)\n    " + lines.joined(separator: "\n    "))
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A `bonnie` token survives outside Swift sources:

            \(offenders.joined(separator: "\n\n"))
            """)
    }
}

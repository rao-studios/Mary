//
//  BrandTokenTests.swift
//  MaryFoundationTests
//
//  WHAT: No trace of the other assistant's name in code or configuration.
//  OUT:  BrandToken scan of Sources, Tests, the manifest, plists, `.mary`
//  PIN:  Comments are exempt; string literals are not. Matched by STEM, not
//        by a list of spellings — see `brandStem`.
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
            .filter { $0.pathComponents.allSatisfy { !excludedDirectoryNames.contains($0) } }
            .sorted { $0.path < $1.path }
    }

    /// THE STEM OF THE OTHER ASSISTANT'S NAME — deliberately not a list of its
    /// spellings. A recognizer spells it a dozen ways, and "bonny", "bonni" and
    /// "bonne" all shipped as live wake-word literals for exactly as long as
    /// this gate enumerated spellings instead of matching the family. An
    /// enumeration is always one homophone behind; every spelling shares this
    /// stem, so one rule also catches the ones nobody has written down yet.
    static let brandStem = "bonn"

    /// Directories holding natural-language DATA rather than code. The Kokoro
    /// pronunciation lexicons legitimately carry "Bonn", "Bourbonnais",
    /// "carbonnade" and the ordinary English word "bonny": there the stem is
    /// vocabulary, not a brand. This gate reads code and configuration —
    /// identifiers, string literals, bundle ids, package format strings —
    /// where the stem can only be the name. KEEP THIS EXCLUSION if the scan
    /// ever widens to resource files.
    static let excludedDirectoryNames: Set<String> = ["Resources"]

    /// Lines of `text` carrying the brand stem, in any casing, as "42: the line".
    static func offendingLines(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.element.range(of: brandStem, options: .caseInsensitive) != nil }
            .map { "\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
    }

    /// NO BRAND STEM IN SWIFT CODE — shipped or test. Test fixtures are
    /// included because that is where the wake-word spellings survived: a
    /// rename half-happens when the sources are cleaned and the tables that
    /// assert against them are not.
    @Test func swiftCodeCarriesNoBrandStemOutsideComments() throws {
        var offenders: [String] = []
        for directory in ["Sources", "Tests"] {
            let root = Self.repositoryRoot.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for file in Self.files(under: root, extensions: ["swift"]) {
                // THE GATE ITSELF NAMES WHAT IT FORBIDS. Nothing else is exempt.
                guard file.lastPathComponent != "BrandTokenTests.swift" else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                let lines = Self.offendingLines(in: Self.stripComments(text))
                guard !lines.isEmpty else { continue }
                let relative = file.path
                    .replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
                offenders.append("\(relative)\n    " + lines.joined(separator: "\n    "))
            }
        }

        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) file(s) carry the `\(Self.brandStem)` stem in code. \
            Comments are exempt; identifiers and string literals are not — a missed \
            literal is how two apps end up sharing one store.

            \(offenders.joined(separator: "\n\n"))
            """)
    }

    /// NO BRAND STEM IN THE MANIFEST, THE BUNDLE PLIST, OR A SHIPPED
    /// PLUGIN PACKAGE. Same reasoning, different file types: the plist carries
    /// the bundle id and the exported UTI, and a Plugin package carries the
    /// format string every reader keys on.
    @Test func manifestPlistAndPackagesCarryNoBrandStem() throws {
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
            The `\(Self.brandStem)` stem survives outside Swift sources:

            \(offenders.joined(separator: "\n\n"))
            """)
    }
}

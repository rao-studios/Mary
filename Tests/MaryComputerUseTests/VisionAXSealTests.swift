//
//  VisionAXSealTests.swift
//  MaryComputerUseTests
//
//  WHAT: VisionAX stays behind one door, and none of its types cross it.
//  OUT:  Source-text scan of Sources/
//  PIN:  This is not tidiness. VisionAX REPLICATES Mary's AX vocabulary — it declares
//        its own AXNodeSnapshot, AXWindowSnapshot, AXScreenElement and AXNodeCategory
//        under those exact names, deliberately, so its trees are shaped like ours. Two
//        modules declaring the same names means any file importing both makes every use
//        of them ambiguous, and the error appears at the USE, far from the import that
//        caused it. One importing directory is what keeps that from ever happening.
//

import Foundation
import XCTest

final class VisionAXSealTests: XCTestCase {

    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    /// Source with `//` comments removed — this file's rules name what they forbid.
    static func code(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    static func swiftFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil)
        else { throw XCTSkip("Could not enumerate Sources") }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    static func path(_ url: URL) -> String {
        url.path.components(separatedBy: "/Sources/").last.map { "Sources/" + $0 } ?? url.path
    }

    /// The one directory allowed to import it.
    static let door = "Sources/MaryComputerUse/Sight/Vision/"

    func testOnlyTheVisionLaneImportsVisionAX() throws {
        var breaches: [String] = []
        for url in try Self.swiftFiles() {
            let path = Self.path(url)
            let body = Self.code(try String(contentsOf: url, encoding: .utf8))
            guard body.range(of: #"^\s*import VisionAX\b"#, options: [.regularExpression]) != nil
                    || body.contains("\nimport VisionAX")
                    || body.hasPrefix("import VisionAX")
            else { continue }
            if path.hasPrefix(Self.door) { continue }
            breaches.append(path)
        }
        XCTAssertTrue(
            breaches.isEmpty,
            """
            These files import VisionAX from outside \(Self.door):
            \(breaches.joined(separator: "\n"))

            VisionAX declares AXNodeSnapshot, AXWindowSnapshot, AXScreenElement and \
            AXNodeCategory under the same names Mary does. A file that imports both \
            modules makes every use of those names ambiguous, and the compiler reports \
            it at the use rather than at the import. Convert at the seam instead.
            """)
    }

    /// The door must actually be in use — a rule guarding nothing passes forever.
    func testTheVisionLaneExistsAndImportsIt() throws {
        let importers = try Self.swiftFiles()
            .filter { Self.path($0).hasPrefix(Self.door) }
            .filter { Self.code(try! String(contentsOf: $0, encoding: .utf8)).contains("import VisionAX") }
        XCTAssertFalse(
            importers.isEmpty,
            "nothing under \(Self.door) imports VisionAX — this test is guarding an empty room")
    }

    /// NO VISIONAX TYPE APPEARS IN A PUBLIC SIGNATURE. Everything crosses the seam as
    /// Mary's own value types, so a caller never has to import the package to hold
    /// what it produced.
    func testNoPublicSignatureNamesAVisionAXType() throws {
        let foreign = [
            "VisionScene", "VisionDetection", "VisionEngine", "VisionLanes",
            "MediaControlDetection", "ScreenProjection", "RegionClassifier",
            "MediaGlyph", "TextRun", "CannyOptions",
            // The map's vocabulary. Mary's twins are PageMapSummary, SeenAffordance
            // and SeenLabelSource — same facts, this module's names.
            "PageMap", "PageMapElement", "PageMapGroup", "PageAffordance",
            "PageLabelSource", "PageAffordanceSource", "TextLine", "IconGlyph",
        ]
        var breaches: [String] = []
        for url in try Self.swiftFiles()
        where Self.path(url).hasPrefix("Sources/MaryComputerUse/") {
            let body = Self.code(try String(contentsOf: url, encoding: .utf8))
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.contains("public ") || line.contains("package ") else { continue }
                for type in foreign where line.range(
                    of: "\\b\(type)\\b", options: .regularExpression) != nil {
                    breaches.append("\(Self.path(url)): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(
            breaches.isEmpty,
            """
            These public signatures name a VisionAX type:
            \(breaches.joined(separator: "\n"))

            Convert at the seam (VisionPageReader) and publish Mary's own types, so \
            nothing above this layer needs the package to hold what it produced.
            """)
    }
}

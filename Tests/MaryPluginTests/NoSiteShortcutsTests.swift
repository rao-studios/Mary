//
//  NoSiteShortcutsTests.swift
//  MaryPluginTests
//
//  WHAT: The browsing lane drives a page by pressing what the page draws.
//  OUT:  Source-text scan of Sources/MaryPlugin/WebSurface/
//  PIN:  THREE SHORTCUTS THIS LANE WILL NOT TAKE, and each one is tempting because each
//        one is easier than what it replaces.
//        A SITE'S OWN KEYS (`k`, `j`, `l`, `m`, `f` on one video site) work until the
//        page is a different site, or the focus is in a comment box, where they type
//        letters into somebody's draft instead.
//        THE SYSTEM MEDIA KEYS reach whatever holds the now-playing role — on a machine
//        with a music player open, that is not this tab, and the wrong thing pauses.
//        SCRIPTING a browser skips the page entirely and only one browser answers,
//        which is the split this whole design exists to remove.
//        The rule is not a sentence in a document; it is this test.
//

import Foundation
import XCTest

final class NoSiteShortcutsTests: XCTestCase {

    static let lane = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MaryPlugin/WebSurface", isDirectory: true)

    /// Source with `//` comments removed — this test names what it forbids.
    static func code(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    static func files() throws -> [(path: String, body: String)] {
        guard let enumerator = FileManager.default.enumerator(
            at: lane, includingPropertiesForKeys: nil)
        else { throw XCTSkip("the browsing lane is not present") }
        return try enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, code(try String(contentsOf: $0, encoding: .utf8))) }
    }

    func testTheLaneNeverReachesForTheSystemMediaKeys() throws {
        let offenders = try Self.files()
            .filter { $0.body.contains("MediaTransport") }
            .map(\.path)
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(offenders.joined(separator: ", ")) names MediaTransport. A media key goes \
            to whatever process holds the system's now-playing role, which is not \
            necessarily the tab anyone is looking at. Press the control the page draws.
            """)
    }

    func testTheLaneNeverScriptsABrowser() throws {
        let forbidden = ["NSAppleScript", "osascript", "AEDesc", "do JavaScript",
                         "evaluateJavaScript", "ScriptingBridge"]
        var offences: [String] = []
        for file in try Self.files() {
            for token in forbidden where file.body.contains(token) {
                offences.append("\(file.path) names \(token)")
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            """
            \(offences.joined(separator: "\n"))

            Scripting reaches past the page and only one browser answers. The page is \
            read from pixels and pressed where it was seen.
            """)
    }

    /// A LETTER WITH NO MODIFIER IS A SITE SHORTCUT. Every chord this lane presses is a
    /// browser command with a modifier on it; a bare letter is a key that means
    /// something only to whatever page happens to be open.
    func testTheLaneNeverPressesABareLetter() throws {
        var offences: [String] = []
        for file in try Self.files() {
            let lines = file.body.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("KeyChordPress.press(") {
                let window = lines[index..<min(index + 3, lines.count)].joined(separator: " ")
                guard window.contains("modifiers:") else {
                    offences.append("\(file.path):\(index + 1) presses a key with no modifiers")
                    continue
                }
                if window.contains("modifiers: [])") {
                    // Return, Escape and Tab carry no modifier and are not site
                    // shortcuts. Nor is forward-delete: it is a text-editing key, used
                    // inside a field the lane has just typed into, to remove the inline
                    // completion a browser added before Return accepts it. Measured
                    // live — a typed query opened a history entry instead of searching.
                    let allowed = [
                        "key: .return", "key: .escape", "key: .tab", "key: .forwardDelete",
                    ]
                    if !allowed.contains(where: { window.contains($0) }) {
                        offences.append("\(file.path):\(index + 1) presses an unmodified key")
                    }
                }
            }
        }
        XCTAssertTrue(
            offences.isEmpty,
            """
            \(offences.joined(separator: "\n"))

            An unmodified letter is a shortcut belonging to whatever page is open, and \
            with the focus in a text field it types into somebody's draft instead.
            """)
    }

    /// The rule must be able to fail.
    func testTheRuleWouldCatchWhatItForbids() {
        let regression = "_ = KeyChordPress.press(key: .k, modifiers: [])"
        XCTAssertTrue(Self.code(regression).contains("KeyChordPress.press("))
        XCTAssertTrue(Self.code(regression).contains("modifiers: [])"))
    }
}

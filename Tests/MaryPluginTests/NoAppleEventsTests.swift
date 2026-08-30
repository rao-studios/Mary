//
//  NoAppleEventsTests.swift
//  MaryPluginTests
//
//  WHAT: MaryPlugin sources must not send Apple Events.
//  OUT:  Source-text scan of Sources/MaryPlugin
//  PIN:  AEDeterminePermissionToAutomateTarget is a query, not a send.
//        Subprocess is open / git / declared-build only.
//

import Foundation
import XCTest

final class NoAppleEventsTests: XCTestCase {

    /// Every Swift file under `Sources`, minus the one place a permission
    /// QUERY legitimately lives.
    private static func sources() throws -> [(text: String, name: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate Sources")
            return []
        }
        return try enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            // The permission centre asks macOS whether consent EXISTS. It
            // sends nothing, and it is the one file allowed to name the API.
            .filter { $0.lastPathComponent != "PermissionsCenter.swift" }
            .map { (try String(contentsOf: $0, encoding: .utf8), $0.lastPathComponent) }
    }

    /// Comments discuss the road not taken at length, and should: half the
    /// value of these headers is explaining why the scripted answer was
    /// rejected. Only CODE is the violation.
    ///
    /// TRAILING COMMENTS COUNT AS COMMENTS, and it matters immediately: a
    /// timeout table in `AbilityRuntime` annotates its rows
    /// `// Subprocess.run(timeout: 300)`, and reading those as code reports a
    /// shell call in a dictionary of integers. (Those rows are themselves
    /// vestigial — they budget skills this build does not have.)
    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                if trimmed.hasPrefix("//") { return "" }
                if let comment = line.range(of: "//") {
                    return line[line.startIndex..<comment.lowerBound]
                }
                return line
            }
            .joined(separator: "\n")
    }

    func testNothingSendsAnAppleEvent() throws {
        // The ways to send one, and the shell that would carry a script.
        //
        // NOT the bare word "osascript": a turn matches it as an UTTERANCE
        // TOKEN so Mary can recognise a request to run a script and decline
        // it. Failing the build on a refusal detector would be the gate
        // crying wolf at the one file doing the right thing — the violation
        // is EXECUTING the tool, so the path is what is forbidden.
        let forbidden = [
            "NSAppleScript",
            "OSAScript",
            "AESendMessage",
            "NSAppleEventDescriptor",
            "/usr/bin/osascript",
            "NSUserAppleScriptTask",
        ]
        for (text, name) in try Self.sources() {
            let source = code(text)
            for token in forbidden {
                XCTAssertFalse(
                    source.contains(token),
                    """
                    \(name) reaches for \(token). Mary drives applications through \
                    Accessibility; an Apple Event here reintroduces a consent she \
                    otherwise never needs, and it will work, which is what makes it \
                    worth failing the build over.
                    """)
            }
        }
    }

    /// SUBPROCESS HAS THREE PRODUCTION ERRANDS, all Mary-owned:
    /// `/usr/bin/open` (Launch Services), `/usr/bin/git`, and a project's
    /// declared build command. A general shell is the escape hatch the
    /// runtime primitives were deleted to close.
    func testSubprocessOnlyRunsMaryOwnedTools() throws {
        let allowedByFile: [String: String] = [
            "Subprocess.swift": "",
            "WindowManagement.swift": "\"/usr/bin/open\"",
            "ProjectGitAdapter.swift": "\"/usr/bin/git\"",
            "ProjectBuildAdapter.swift": "Subprocess.run(",
        ]
        let forbiddenShells = ["/bin/sh", "/bin/zsh", "/bin/bash", "/usr/bin/env"]
        for (text, name) in try Self.sources() {
            let source = code(text)
            guard source.contains("Subprocess.run(") else { continue }
            guard let required = allowedByFile[name] else {
                XCTFail("""
                    \(name) runs a subprocess. Only WindowManagement (/usr/bin/open), \
                    ProjectGitAdapter (/usr/bin/git), and ProjectBuildAdapter (declared \
                    build command) may. A general shell is the escape hatch this build \
                    deleted its runtime primitives to close.
                    """)
                continue
            }
            if !required.isEmpty {
                XCTAssertTrue(
                    source.contains(required),
                    "\(name) no longer names the tool this gate allows")
            }
            for shell in forbiddenShells {
                XCTAssertFalse(
                    source.contains(shell),
                    "\(name) reaches for \(shell)")
            }
        }
    }

    /// THE MENU DRIVER IS THE REPLACEMENT, and this pins that it stayed one.
    /// Its predecessor asked System Events to click menus; a regression would
    /// most likely arrive here, in the file whose job is exactly what the
    /// scripted version did.
    func testTheMenuDriverPressesThroughAccessibility() throws {
        let driver = try XCTUnwrap(
            try Self.sources().first { $0.name == "ApplicationMenuDriver.swift" },
            "the menu driver is gone — this gate guards it specifically")
        let source = code(driver.text)
        XCTAssertTrue(
            source.contains("AXUIElementPerformAction"),
            "the menu driver no longer presses through Accessibility")
        XCTAssertFalse(source.contains("System Events"))
    }
}

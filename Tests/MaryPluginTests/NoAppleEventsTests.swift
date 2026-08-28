//
//  NoAppleEventsTests.swift
//  MaryPluginTests
//
//  MARY SENDS NO APPLE EVENTS. A source-text test, because the property is
//  about what the code is ALLOWED to reach rather than about what any run of
//  it does — and because the whole value of the rule is that there is no
//  second place to look.
//
//  WHY IT MATTERS MORE AFTER A PORT THAN BEFORE ONE. Everything this lane
//  descends from drove applications by scripting them: the predecessor's
//  browsing lane read its tab roster with `tell application`, its menu driver
//  clicked through System Events, its media lane was 2,285 lines of
//  AppleScript including the reads. Porting those means meeting a scripted
//  answer at every step and re-founding it on Accessibility, and the failure
//  mode is not a compile error — it is one convenient `NSAppleScript` in an
//  error path, which works, and quietly reintroduces a consent Mary does not
//  otherwise need.
//
//  `VerifiedActivation`'s "NO SECOND ROAD" comment is the doctrine; this is
//  the enforcement.
//
//  ⚠️ WHAT THIS DOES NOT COVER, said plainly rather than left to be
//  discovered: `PermissionsCenter` still asks for Automation CONSENT for
//  every application in the roster, using `AEDeterminePermissionToAutomateTarget`
//  — which is a permission QUERY and sends no event, so it is not a
//  violation of this rule. But it means the user is asked to grant a
//  capability this build cannot exercise, which Mary's own doctrine calls a
//  consent request with nothing behind it. Left alone here because what
//  consent an application requests is a product decision rather than a
//  cleanup, and because this port only made it more visible (more
//  applications now have eyes) rather than introducing it.
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
    /// TRAILING COMMENTS COUNT AS COMMENTS, which the first version of this
    /// missed — and it mattered immediately: a timeout table in
    /// `AbilityRuntime` annotates its rows `// Subprocess.run(timeout: 300)`,
    /// and reading those as code reported a shell call in a dictionary of
    /// integers. (Those rows are themselves vestigial: they budget skills —
    /// run_tests, run_shortcut, zip_folder — that this build does not have.)
    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                if trimmed.hasPrefix("//") { return "" }
                if let comment = line.range(of: "//") { return line[line.startIndex..<comment.lowerBound] }
                return line
            }
            .joined(separator: "\n")
    }

    func testNothingSendsAnAppleEvent() throws {
        // The ways to send one, and the shell that would carry a script.
        //
        // NOT the bare word "osascript": `WindowManagementTurn` matches it as
        // an UTTERANCE TOKEN, so that Mary can recognise a request to run a
        // script and decline it. Failing the build on a refusal detector
        // would be the gate crying wolf at the one file doing the right
        // thing — the violation is EXECUTING the tool, so the path is what
        // is forbidden.
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

    /// SUBPROCESS HAS EXACTLY ONE PRODUCTION ERRAND. It survived the
    /// AppleScript lane's removal because window management opens files with
    /// `/usr/bin/open`, which talks to Launch Services rather than to an
    /// application — and a general shell would be the escape hatch the
    /// runtime primitives were deleted for.
    func testSubprocessOnlyRunsTheOpenTool() throws {
        for (text, name) in try Self.sources() {
            // Probes are diagnostics run by hand, not paths a turn takes.
            guard !name.hasPrefix("WebProbe"), !name.hasPrefix("MenuProbe"),
                  !name.hasPrefix("ProjectProbe") else { continue }
            let source = code(text)
            guard source.contains("Subprocess.run(") else { continue }
            // The declaration itself, and the one caller.
            guard name != "Subprocess.swift" else { continue }
            XCTAssertTrue(
                source.contains("\"/usr/bin/open\""),
                """
                \(name) runs a subprocess that is not /usr/bin/open. A general \
                shell is the escape hatch this build deleted its runtime \
                primitives to close.
                """)
        }
    }
}

//
//  OnlyComputerUseTouchesTheMachineTests.swift
//  MaryComputerUseTests
//
//  WHAT: The two standing rules of the machine layer, read from the sources.
//  OUT:  Source-text scan of Sources/
//  PIN:  This test exists because the boundary it guards was breached exactly
//        this way before: MaryBrain grew its own CGEvent poster and its own AX
//        walk inside the pointer lane, and nothing failed. A forbidden call
//        compiles, links, ships, and the layer is simply gone.
//

import Foundation
import XCTest

final class OnlyComputerUseTouchesTheMachineTests: XCTestCase {

    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    /// Source with `//` comments removed. These rules NAME the things they
    /// forbid, so a rule quoted in a doc comment must not read as a breach.
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

    // MARK: - Rule one: the acts belong to MaryComputerUse

    /// Posting an input event, performing an Accessibility action, and taking
    /// a picture of the screen are ACTS. They live in one target so that the
    /// question "what can Mary do to my Mac" has one place to look, and so
    /// that every act passes the one monitor that can report it.
    ///
    /// Reads are deliberately absent from this list: `AXUIElementCopyAttributeValue`,
    /// `AXIsProcessTrusted` and `NSRunningApplication(processIdentifier:)` answer
    /// questions without changing anything, and MaryAmbient's selection lane
    /// depends on being able to ask them.
    static let forbidden = [
        "CGEvent(", ".postToPid(", ".post(tap:",
        "CGWarpMouseCursorPosition", "CGDisplayMoveCursorToPoint",
        "AXUIElementPerformAction", "AXUIElementSetAttributeValue",
        "NSEvent.otherEvent(", ".activate(options:",
        "SCScreenshotManager", "CGWindowListCreateImage", "CGDisplayCreateImage",
    ]

    /// Directories below the machine layer, or beside it by doctrine.
    static let exemptPrefixes = [
        // The layer itself.
        "Sources/MaryComputerUse/",
        // MaryAmbient reads AX for its own selection lane and must keep doing
        // it on MaryFoundation alone — `ambientDependsOnFoundationAlone`
        // forbids the edge that would let it borrow this layer instead.
        "Sources/MaryAmbient/Selection/",
    ]

    /// Files that act outside the layer, each with the reason it is tolerated
    /// and a token that must still be present — so a file renamed or
    /// repurposed falls out of the allowlist rather than inheriting it.
    ///
    /// Two of these are duplicated hands, and they are FLAGGED, not blessed:
    /// `MediaSurfaceLibrary.press` is a second copy of `PageElementActions.press`,
    /// and `ProseSurfaceAX` sets selection ranges directly. Both should route
    /// through Hands/ — a follow-up, deliberately not folded into the move
    /// that created this test.
    static let allowed: [String: String] = [
        // Hand-run diagnostics. A probe that could not drive the machine could
        // not diagnose it.
        "Sources/Probes/CorpusProbe/CodeSurfaceProbe.swift": "AXUIElementSetAttributeValue",
        "Sources/Probes/MediaProbe/main.swift": "AXUIElementPerformAction",
        "Sources/MaryApp/ProbeCursorText.swift": "--probe-cursor-text",
        // App-side pixels: Screen Recording is asked for in the app, and
        // MaryBrain stays cheap on permissions because of it.
        "Sources/MaryRuntime/Services/Capture/WindowCaptureService.swift": "SCScreenshotManager",
        // FLAGGED duplicates of Hands/ work — see the note above.
        "Sources/MaryPlugin/MediaSurface/MediaSurfaceLibrary.swift": "kAXDisclosingAttribute",
        "Sources/MaryPlugin/ProseSurface/ProseSurfaceAX.swift": "kAXSelectedTextRangeAttribute",
    ]

    func testNothingOutsideTheMachineLayerActsOnTheMachine() throws {
        var breaches: [String] = []
        for url in try Self.swiftFiles() {
            let path = Self.path(url)
            if Self.exemptPrefixes.contains(where: { path.hasPrefix($0) }) { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let body = Self.code(source)
            let found = Self.forbidden.filter { body.contains($0) }
            guard !found.isEmpty else { continue }

            if let required = Self.allowed[path] {
                XCTAssertTrue(
                    source.contains(required),
                    """
                    \(path) is on the machine-touch allowlist for a reason that \
                    no longer applies — it no longer contains \(required). Remove \
                    the entry or route the act through MaryComputerUse.
                    """)
                continue
            }
            breaches.append("\(path) → \(found.joined(separator: ", "))")
        }
        XCTAssertTrue(
            breaches.isEmpty,
            """
            These files act on the machine from outside MaryComputerUse:
            \(breaches.joined(separator: "\n"))

            Route the act through Hands/ (or Sight/, for a capture). A second \
            place that synthesizes input is a second place that has to get the \
            modifier flags, the event tap, the release and the target pid right \
            — and it is invisible to the monitor, so a person watching Mary's \
            hands cannot see it happen.
            """)
    }

    /// The list must be able to fail. A token list that matches nothing would
    /// pass forever, including on the exact regression it was written for.
    func testTheRuleWouldCatchTheRegressionItWasWrittenFor() {
        let regression = """
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: point, mouseButton: button)
            event.postToPid(pid)
            """
        let caught = Self.forbidden.filter { Self.code(regression).contains($0) }
        XCTAssertTrue(
            caught.contains("CGEvent("),
            "the rule no longer catches an inline event synthesizer")
        XCTAssertTrue(
            caught.contains(".postToPid("),
            "the rule no longer catches a pid-posted event")
    }

    /// A comment is not a breach — the rules name what they forbid.
    func testDocumentingARuleIsNotBreakingIt() {
        XCTAssertFalse(Self.code("// we never call AXUIElementPerformAction here")
            .contains("AXUIElementPerformAction"))
    }

    // MARK: - Rule two: tier 0 stands alone

    /// ACCESSIBILITY/ IS THE FLOOR. The tree read must not reach up into the
    /// lanes built on top of it, or "tier 0" stops meaning anything: a walk
    /// that consulted the hands could not be reasoned about, reused, or
    /// tested without them.
    ///
    /// The single exception is the monitor, which every lane reports into.
    func testTheAccessibilityTierNamesNothingAboveIt() throws {
        let root = Self.sourceRoot.appendingPathComponent("MaryComputerUse", isDirectory: true)
        let upperLanes = ["Sight", "Hands", "Stage", "Process"]

        // Every top-level type declared in the lanes above tier 0.
        let declaration = try NSRegularExpression(
            pattern: #"^(?:public |package |)(?:final )?(?:actor|class|struct|enum|protocol) ([A-Z]\w*)"#,
            options: [.anchorsMatchLines])
        var upperTypes: Set<String> = []
        for url in try Self.swiftFiles() where Self.path(url).hasPrefix("Sources/MaryComputerUse/") {
            let path = Self.path(url)
            guard upperLanes.contains(where: { path.contains("/MaryComputerUse/\($0)/") }) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in declaration.matches(in: source, range: range) {
                if let r = Range(match.range(at: 1), in: source) { upperTypes.insert(String(source[r])) }
            }
        }
        XCTAssertFalse(
            upperTypes.isEmpty,
            "found no types in the upper lanes — this test is reading the wrong tree")

        var breaches: [String] = []
        let accessibility = root.appendingPathComponent("Accessibility", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: accessibility, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let body = Self.code(try String(contentsOf: url, encoding: .utf8))
            for type in upperTypes.sorted() {
                // The monitor is the one thing tier 0 may name: a walk reports
                // what it cost, and nothing else.
                if type == "ComputerUseMonitor" { continue }
                if body.range(of: "\\b\(type)\\b", options: .regularExpression) != nil {
                    breaches.append("\(Self.path(url)) names \(type)")
                }
            }
        }
        XCTAssertTrue(
            breaches.isEmpty,
            """
            Accessibility/ (tier 0) reaches up into a lane built on it:
            \(breaches.joined(separator: "\n"))

            The tree read is the floor everything else stands on. Move the \
            shared piece down into Accessibility/, or invert the call the way \
            AXWindowRoster and AccessibilityWindowCore were inverted.
            """)
    }
}

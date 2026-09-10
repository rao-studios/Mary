//
//  MediaSurfaceCancellationTests.swift
//  MaryPluginTests
//
//  WHAT: Stop means stop, not hurry — a cancelled caller must not press.
//  OUT:  MediaSurfaceLibrary.play / press / pressButton
//  PIN:  `MediaSurfaceLibrary` had NO `Task.isCancelled` checks at all before
//        this; every sleep was `try?`, so cancelling a slow `play` made the
//        remaining presses fire FASTER, never stopped them.
//
//        A RUNTIME TEST CANNOT DISTINGUISH THIS FIX FROM ITS ABSENCE.
//        `AXUIElementPerformAction` on a synthetic element with no
//        Accessibility trust already fails instantly and returns `false` on
//        its own — cancelled or not, `press` returns the same value either
//        way, and a race-based `Task.cancel()` test that "passes" proves
//        nothing (measured: it kept passing after the guard was deleted).
//        So this suite reads the source as text instead — the same technique
//        `PackageLayeringTests` uses for an invariant the runtime cannot
//        check on its own. Real proof of the fix is the live step this
//        change's plan calls for: start a long playlist, hit Stop mid-flight,
//        confirm no further presses land in Apple Music.
//

import Foundation
import Testing

@Suite struct MediaSurfaceCancellationTests {

    static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaryPluginTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(
                "Sources/MaryPlugin/MediaSurface/MediaSurfaceLibrary.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The two side-effecting primitives must refuse before they touch
    /// Accessibility at all — as their very first statement, not somewhere
    /// after a snapshot has already been built or a press already issued.
    @Test func pressAndPressButtonGuardBeforeAnyAccessibilityCall() throws {
        #expect(!Self.source.isEmpty, "could not read MediaSurfaceLibrary.swift")
        let source = Self.source
        for signature in [
            "static func press(_ element: AXUIElement, pid: pid_t) async -> Bool {",
            "private static func pressButton(",
        ] {
            let range = try #require(source.range(of: signature))
            let afterSignature = source[range.upperBound...]
            // The function's own opening brace for `pressButton` is on the
            // next line (multi-line signature); walk to the first `{` that
            // starts the body.
            let bodyStart = signature.hasSuffix("{")
                ? afterSignature.startIndex
                : (afterSignature.firstIndex(of: "{").map { afterSignature.index(after: $0) }
                    ?? afterSignature.startIndex)
            let body = afterSignature[bodyStart...].prefix(200)
            let firstStatement = body
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            #expect(
                firstStatement == "guard !Task.isCancelled else { return false }",
                "\(signature) — first statement was: \(firstStatement)")
        }
    }

    /// `play`'s three post-resolution steps — select, the navigation settle,
    /// and the page-play press — must each be preceded by a cancellation
    /// check, so a Stop issued while a slow selection is settling is honoured
    /// before the NEXT step rather than only at the very start of `play`.
    @Test func playGuardsBeforeEachRemainingSideEffectingStep() throws {
        #expect(!Self.source.isEmpty, "could not read MediaSurfaceLibrary.swift")
        let source = Self.source
        let guardLine = "guard !Task.isCancelled else { return .couldNotPress }"
        let occurrences = source.components(separatedBy: guardLine).count - 1
        #expect(occurrences == 3, "expected one guard before select, before the settle sleep, and before pressPagePlay")

        // Ordered relative to the steps they must precede.
        let selectRange = try #require(source.range(of: "await selectRow(row.element)"))
        let sleepRange = try #require(source.range(of: "try? await Task.sleep(nanoseconds: 900_000_000)"))
        let pressPlayRange = try #require(source.range(of: "await pressPagePlay(pid: pid, registration: registration)"))
        let guardsBefore = { (target: Range<String.Index>) -> Int in
            source[source.startIndex..<target.lowerBound]
                .components(separatedBy: guardLine).count - 1
        }
        #expect(guardsBefore(selectRange) == 1)
        #expect(guardsBefore(sleepRange) == 2)
        #expect(guardsBefore(pressPlayRange) == 3)
    }
}

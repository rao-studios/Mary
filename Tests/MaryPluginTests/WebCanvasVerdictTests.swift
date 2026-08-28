//
//  WebCanvasVerdictTests.swift
//  MaryPluginTests
//
//  Pins how a web tool's page is read for a verdict — the one part of the
//  canvas lane where the obvious implementation reports success forever.
//
//  THE TRAP, inherited as a measurement rather than a guess: Shadertoy prints
//  "Compiled in 0.0 secs" whether or not the compile worked. A reader that
//  took that phrase for a success signal would report every run as fine,
//  including the ones printing an error on the line above it — and would keep
//  doing so silently, because the sentence it produced was plausible every
//  time.
//
//  So the ordering is failure-first and the middle case is honest: a page
//  with no diagnostic on it is `.unconfirmed`, never `.succeeded`. There is
//  no `.succeeded`.
//

import MaryFoundation
import XCTest
@testable import MaryPlugin

final class WebCanvasVerdictTests: XCTestCase {

    private var shaderLike: WebCanvasSchema {
        .init(
            address: "https://example.com/new",
            contentNoun: "shader",
            contentLimitBytes: 32000,
            requiredContentMarker: "mainImage",
            runChord: .init(key: .return, modifiers: [.option]),
            diagnosticPhrases: ["ERROR:", "syntax error"],
            statusMarker: "Compiled in")
    }

    private func verdict(_ page: String) -> WebCanvasComposition.Verdict {
        WebCanvasComposition.verdict(pageText: page, canvas: shaderLike)
    }

    // MARK: - Failure is decisive

    func testADeclaredDiagnosticIsAFailure() {
        let page = "Shader Editor\nERROR: 0:14: 'vec3' : syntax error\nCompiled in 0.0 secs"
        guard case .failed(let line) = verdict(page) else {
            return XCTFail("expected a failure")
        }
        // THE TOOL'S OWN WORDS, not "it failed" — the line is what tells the
        // user (and the model, on a retry) what to change.
        XCTAssertTrue(line.contains("0:14"))
        XCTAssertTrue(line.contains("syntax error"))
    }

    /// ⚠️ THE WHOLE POINT. The status marker sits on the same page as the
    /// error, says the run took no time at all, and means nothing. Failure
    /// outranks it.
    func testAStatusMarkerNeverOutranksADiagnostic() {
        let page = "Compiled in 0.0 secs\nERROR: 0:2: undeclared identifier"
        guard case .failed = verdict(page) else {
            return XCTFail("the status marker must not rescue a page with an error on it")
        }
    }

    func testMatchingIsCaseInsensitive() {
        guard case .failed = verdict("error: something went wrong") else {
            return XCTFail("a diagnostic in another case is still a diagnostic")
        }
    }

    // MARK: - The honest middle

    /// A CLEAN PAGE IS NOT A SUCCESS. A tool can fail silently, or in words
    /// nobody listed — so the absence of a diagnostic is the absence of
    /// evidence. There is deliberately no `.succeeded` case to return.
    func testAPageWithNoDiagnosticIsUnconfirmedRatherThanSucceeded() {
        XCTAssertEqual(verdict("Shader Editor\nCompiled in 0.4 secs"), .unconfirmed)
    }

    func testAStatusMarkerAloneProvesNothing() {
        XCTAssertEqual(verdict("Compiled in 1.2 secs"), .unconfirmed)
    }

    func testAnEmptyPageIsUnreadable() {
        XCTAssertEqual(verdict(""), .unreadable)
    }

    /// A canvas that declares no diagnostics can never report a failure, and
    /// that is correct rather than a gap: it has told Mary it knows no words
    /// for failure, so every read is honestly unconfirmed.
    func testACanvasWithNoDeclaredDiagnosticsIsAlwaysUnconfirmed() {
        var mute = shaderLike
        mute.diagnosticPhrases = []
        XCTAssertEqual(
            WebCanvasComposition.verdict(
                pageText: "ERROR: 0:1: everything is broken", canvas: mute),
            .unconfirmed)
    }

    // MARK: - What it says out loud

    func testTheSpokenFormNeverClaimsSuccessOnAnUnconfirmedRun() {
        let spoken = WebCanvasComposition.spoken(
            .unconfirmed, noun: "shader", opening: "Restless, mostly.")
        XCTAssertTrue(spoken.ok)
        XCTAssertTrue(spoken.summary.contains("Restless, mostly."))
        // It says what it saw — a page that did not complain — and does not
        // upgrade that into "it worked".
        XCTAssertTrue(spoken.summary.contains("didn't report a problem"))
        XCTAssertFalse(spoken.summary.lowercased().contains("compiled successfully"))
    }

    func testAFailureIsSpokenAsNotOkAndCarriesTheToolsWords() {
        let spoken = WebCanvasComposition.spoken(
            .failed("ERROR: 0:14: syntax error"), noun: "shader", opening: "Restless.")
        XCTAssertFalse(spoken.ok)
        XCTAssertTrue(spoken.summary.contains("0:14"))
    }
}

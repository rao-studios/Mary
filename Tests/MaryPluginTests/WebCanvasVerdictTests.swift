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
    /// for failure, so a page that ran is honestly unconfirmed however it
    /// looks.
    func testACanvasWithNoDeclaredDiagnosticsNeverReportsAFailure() {
        var mute = shaderLike
        mute.diagnosticPhrases = []
        XCTAssertEqual(
            WebCanvasComposition.verdict(
                pageText: "ERROR: 0:1: everything is broken\nCompiled in 0.1 secs",
                canvas: mute),
            .unconfirmed)
    }

    // MARK: - The marker, read in the one direction it can be trusted

    /// ⚠️ THE OTHER HALF OF THE STATUS MARKER, and the one the lane was
    /// missing. Its PRESENCE proves nothing — that is the trap this file opens
    /// with. But a package that declares such a marker is saying the tool
    /// prints it WHENEVER IT RUNS, so its ABSENCE is positive evidence the run
    /// never happened: the chord missed, or the paste landed somewhere inert.
    ///
    /// Before this case existed, that page returned `.unconfirmed` and Mary
    /// said "it's on screen; the editor didn't report a problem" about a
    /// screen with nothing on it. That is the most convincing wrong answer
    /// this lane can give.
    func testAMissingStatusMarkerMeansTheRunNeverHappened() {
        XCTAssertEqual(verdict("Shader Editor\nNew shader"), .didNotRun)
    }

    func testAPresentStatusMarkerLeavesTheVerdictUnconfirmed() {
        XCTAssertEqual(verdict("Shader Editor\nCompiled in 0.4 secs"), .unconfirmed)
    }

    /// A DIAGNOSTIC STILL OUTRANKS IT. A page carrying an error and no marker
    /// failed; it did not fail to run.
    func testADiagnosticOutranksAMissingMarker() {
        guard case .failed = verdict("ERROR: 0:2: undeclared identifier") else {
            return XCTFail("a diagnostic is decisive whether or not the marker is there")
        }
    }

    /// A canvas that declares NO marker has told Mary it has no way to know
    /// whether the tool ran, so the honest answer stays the middle one. This
    /// is what keeps the new case from becoming a false failure on every tool
    /// that prints nothing.
    func testACanvasWithNoStatusMarkerCannotReportThatItDidNotRun() {
        var quiet = shaderLike
        quiet.statusMarker = nil
        XCTAssertEqual(
            WebCanvasComposition.verdict(pageText: "Shader Editor", canvas: quiet),
            .unconfirmed)
    }

    func testDidNotRunIsSpokenAsNotOkAndNeverClaimsTheScreen() {
        let spoken = WebCanvasComposition.spoken(
            .didNotRun, noun: "shader", opening: "Restless.")
        XCTAssertFalse(spoken.ok)
        XCTAssertTrue(spoken.summary.contains("never reported running it"))
        XCTAssertFalse(spoken.summary.contains("It's on screen"))
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

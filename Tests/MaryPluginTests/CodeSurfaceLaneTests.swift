//
//  CodeSurfaceLaneTests.swift
//  MaryPluginTests
//
//  THE PURE LOGIC BEHIND `read_buffer` AND `read_selection` — windowing and
//  identity resolution, the parts that need no live Accessibility tree to
//  pin. The live half — a real Xcode, a real buffer, a real selection — runs
//  as `mary-corpus-probe project --dispatch-code-surface` (see its header for
//  why the corpus probe binary rather than a new one).
//

import Foundation
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class CodeSurfaceLaneTests: XCTestCase {

    // MARK: - The whole-buffer excerpt

    func testWithNoFindPhraseTheWholeBufferIsReturnedUpToTheCeiling() {
        let text = String(repeating: "x", count: 100)
        let budgets = PluginProseBudgetSchema(
            wholeDocumentCharacters: 40, regionCharacters: 20, ambientExcerptCharacters: 10)
        let body = CodeSurfaceAdapter.excerpt(text, around: nil, budgets: budgets)
        XCTAssertEqual(body.count, 40)
    }

    func testAFindPhraseThatIsNotPresentFallsBackToTheWholeBuffer() {
        let text = "the quick brown fox"
        let budgets = PluginProseBudgetSchema(
            wholeDocumentCharacters: 100, regionCharacters: 20, ambientExcerptCharacters: 10)
        let body = CodeSurfaceAdapter.excerpt(text, around: "zebra", budgets: budgets)
        XCTAssertEqual(body, text)
    }

    /// THE WINDOW IS CENTERED ON THE MATCH, not on the start of the buffer —
    /// the property that makes `find` useful for a long file: the caller
    /// gets the neighbourhood of the word they asked about, not the head of
    /// the file with the word possibly nowhere in view.
    func testAFindPhraseReturnsAWindowCenteredOnTheMatch() {
        let text = "AAAAAAAAAA needle BBBBBBBBBB"
        let budgets = PluginProseBudgetSchema(
            wholeDocumentCharacters: 1000, regionCharacters: 10, ambientExcerptCharacters: 10)
        let body = CodeSurfaceAdapter.excerpt(text, around: "needle", budgets: budgets)
        XCTAssertTrue(body.contains("needle"), "the match itself must survive the window")
        XCTAssertTrue(body.count < text.count, "a tight region must actually narrow the read")
    }

    func testAFindPhraseNearTheStartClampsRatherThanUnderflows() {
        let text = "needle right at the start of the buffer, well past the region window"
        let budgets = PluginProseBudgetSchema(
            wholeDocumentCharacters: 1000, regionCharacters: 10, ambientExcerptCharacters: 10)
        // No crash and the match still present is the whole assertion — a
        // window that walked past `startIndex` would trap before either
        // check ran.
        let body = CodeSurfaceAdapter.excerpt(text, around: "needle", budgets: budgets)
        XCTAssertTrue(body.contains("needle"))
    }

    // MARK: - The declaration outline

    /// `declarations(in:patterns:)`'s whole job is one flatten-and-sort over
    /// whatever patterns a package declared — `xcode.mary`'s type pattern
    /// and its `func` sibling, in this test, matching the real shape those
    /// two patterns take in the shipped package (pinned separately, against
    /// the real bytes, in `CorpusStyleReaderTests`).
    func testDeclarationsMergesAndOrdersAcrossPatterns() {
        let source = """
        struct A {
            func one() {}
        }
        func two() {}
        """
        let found = CodeSurfaceAdapter.declarations(
            in: source,
            patterns: [
                #"\b(?:struct|class|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
                #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            ])
        XCTAssertEqual(found.map(\.name), ["A", "one", "two"])
        XCTAssertEqual(found.map(\.line), [1, 2, 4])
    }

    func testDeclarationsOnEmptyTextIsEmpty() {
        XCTAssertTrue(CodeSurfaceAdapter.declarations(
            in: "", patterns: [#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#]).isEmpty)
    }

    func testDeclarationsWithNoMatchingPatternsIsEmpty() {
        XCTAssertTrue(CodeSurfaceAdapter.declarations(
            in: "let x = 1\n", patterns: [#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#]).isEmpty)
    }

    // MARK: - Which application

    /// EXACT-BUNDLE AND FAMILY MATCHING, on `ProseSurfaceRegistration.owns`'s
    /// same contract — a registration must recognize its own bundle
    /// case-insensitively and refuse an unrelated one that merely contains
    /// its name.
    func testARegistrationOwnsItsExactBundleIdentifierCaseInsensitively() {
        let registration = Self.xcodeLikeRegistration()
        XCTAssertTrue(registration.owns(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(registration.owns(bundleID: "COM.APPLE.DT.XCODE"))
        XCTAssertFalse(registration.owns(bundleID: "com.example.notxcode"))
    }

    /// THE ROLE NAMES ARE AX-SPELLED, not the schema's own lower-camel
    /// vocabulary — `.textArea` must become `"AXTextArea"`, the literal
    /// string the walk compares against.
    func testEditorRoleNamesAreAXSpelled() {
        XCTAssertEqual(Self.xcodeLikeRegistration().editorRoleNames, ["AXTextArea"])
    }

    /// A REGISTRATION SHAPED LIKE `xcode.mary`'s OWN DECLARATION, built in
    /// Swift rather than read from the `.mary` file so this test needs
    /// nothing on disk — the same reason `PackageFixtures` builds its own
    /// fixtures instead of hand-editing JSON.
    private static func xcodeLikeRegistration() -> CodeSurfaceRegistration {
        CodeSurfaceRegistration(
            applicationID: "xcode",
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            displayName: "Xcode",
            schema: PluginCodeSurfaceSchema(
                handlePrefix: "C",
                editorRoles: [.textArea],
                documentKey: .documentPathThenWindow,
                budgets: .init(
                    wholeDocumentCharacters: 20000,
                    regionCharacters: 4000,
                    ambientExcerptCharacters: 500)))
    }
}

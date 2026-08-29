//
//  CodeCursorScopeTests.swift
//  MaryPluginTests
//
//  THE PURE HALF OF THE STANDING CURSOR CONTRIBUTION — the windowing, the
//  line count, and the indentation walk that infers which declarations are
//  still open at the caret. None of it needs an editor, so all of it is
//  pinned here rather than only by the live probe
//  (`mary-corpus-probe project --dispatch-code-surface --cursor-scope`).
//
//  The patterns below are `xcode.mary`'s OWN declared
//  `corpus.relations.declarations` regexes, copied verbatim, for the same
//  reason `CodeSurfaceLaneTests` copies them: this lane runs whatever a
//  package declared, and testing it against a friendlier invented pattern
//  would pin a behaviour the shipped package does not have.
//

import Foundation
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class CodeCursorScopeTests: XCTestCase {

    private let patterns = [
        #"\b(?:struct|class|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
        #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#,
    ]

    // MARK: - Where the caret is

    func testTheLineNumberIsOneMoreThanTheNewlinesBeforeTheCaret() {
        XCTAssertEqual(CodeCursorScope.lineNumber(before: ""), 1)
        XCTAssertEqual(CodeCursorScope.lineNumber(before: "one line, no break"), 1)
        XCTAssertEqual(CodeCursorScope.lineNumber(before: "a\nb\nc"), 3)
        XCTAssertEqual(CodeCursorScope.lineNumber(before: "a\nb\n"), 3)
    }

    // MARK: - The enclosing chain

    /// THE SHAPE THIS FEATURE EXISTS FOR — Bonnie's "struct X → var body",
    /// as far as `xcode.mary`'s declared patterns can express it.
    func testTheChainNamesTheOpenDeclarationsOutermostFirst() {
        let prefix = """
        import Foundation

        struct Ledger {
            func record() {
                let total = 0
        """
        let reading = CodeCursorScope.reading(
            prefix: prefix, excerpt: "", patterns: patterns)
        XCTAssertEqual(reading.chain, ["Ledger", "record"])
        // Five lines above the caret, and the caret is on the fifth.
        XCTAssertEqual(reading.line, 5)
    }

    /// A SIBLING THAT HAS ALREADY CLOSED IS NOT AN ANCESTOR. This is the case
    /// that makes the indentation walk worth having: `capturesWithLines`
    /// reports every declaration above the caret, and a flat "last few" would
    /// name a function the caret is nowhere inside.
    func testAClosedSiblingIsSkippedRatherThanNamed() {
        let prefix = """
        struct Ledger {
            func first() {
                let a = 1
            }

            func second() {
                let b = 2
        """
        let reading = CodeCursorScope.reading(
            prefix: prefix, excerpt: "", patterns: patterns)
        XCTAssertEqual(reading.chain, ["Ledger", "second"])
        XCTAssertFalse(reading.chain.contains("first"))
    }

    /// A TYPE THAT CLOSED ENTIRELY takes its members with it — the caret is
    /// inside the NEXT top-level declaration, and nothing above it is open.
    func testAClosedTypeLeavesOnlyTheOneTheCaretIsIn() {
        let prefix = """
        struct First {
            func inner() {
            }
        }

        struct Second {
        """
        let reading = CodeCursorScope.reading(
            prefix: prefix, excerpt: "", patterns: patterns)
        XCTAssertEqual(reading.chain, ["Second"])
    }

    /// RULE 2, AND THE LIVE FAILURE IT CLOSES. Measured against a real
    /// editor before this rule existed: the caret sat at column 4 inside a
    /// `private var` — a member `xcode.mary` declares no pattern for — and
    /// the nearest declaration above it was a nested `func` at column 8 that
    /// had closed a hundred and seventy lines earlier. With only the
    /// decreasing-indent rule there was nothing later at a smaller indent to
    /// knock it out, and the scope line confidently named a function the
    /// caret was nowhere inside.
    func testADeclarationIndentedPastTheCaretCannotEncloseIt() {
        let prefix = """
        struct Adapter {

            var manifest: Manifest {
                func operation(_ name: String) -> Binding {
                    Binding(name)
                }
                return Manifest()
            }

            /// A doc comment on a member with no declared pattern.
            /// The caret is here
        """
        let reading = CodeCursorScope.reading(
            prefix: prefix, excerpt: "", patterns: patterns)
        XCTAssertEqual(
            reading.chain, ["Adapter"],
            "a func at column 8 cannot contain a caret at column 4")
    }

    /// THE ONE EXCEPTION to rule 2 — the caret is inside what it is in the
    /// middle of declaring, even though that declaration shares its column.
    func testADeclarationOnTheCaretsOwnLineStillCounts() {
        let prefix = """
        struct Ledger {
            func record
        """
        let reading = CodeCursorScope.reading(
            prefix: prefix, excerpt: "", patterns: patterns)
        XCTAssertEqual(reading.chain, ["Ledger", "record"])
    }

    /// A CARET STANDING IN A LINE'S INDENTATION IS AT THAT COLUMN, not at
    /// the column of the line above it. Found live: a probe caret at column
    /// 12 inside a nested function's body borrowed the enclosing `func`'s own
    /// column 8 from the line above and then excluded that very `func` from
    /// its own chain.
    func testACaretInsideALinesIndentationMeasuresThatIndentation() {
        let prefix = """
        struct Adapter {
            var manifest: Manifest {
                func operation() -> Binding {
        \("            ")
        """
        let reading = CodeCursorScope.reading(
            prefix: prefix, excerpt: "", patterns: patterns)
        XCTAssertEqual(reading.chain, ["Adapter", "operation"])
    }

    /// A CARET ON AN EMPTY LINE reads its column from the block it is
    /// standing in — otherwise column 0 would knock every declaration out and
    /// leave a bare line number.
    func testACaretOnABlankLineTakesTheColumnOfTheBlockItIsIn() {
        let prefix = """
        struct Ledger {
            func record() {
                let total = 0

        """
        let reading = CodeCursorScope.reading(
            prefix: prefix, excerpt: "", patterns: patterns)
        XCTAssertEqual(reading.chain, ["Ledger", "record"])
    }

    func testTheChainKeepsTheInnermostLinksWhenItIsDeeperThanTheLimit() {
        let declarations = (1...6).map {
            CorpusPatterns.PositionedCapture(name: "level\($0)", line: $0)
        }
        let indentations = (0..<6).map { $0 * 4 }
        let chain = CodeCursorScope.chain(
            declarations: declarations, indentations: indentations,
            caretLine: 7, caretIndent: 24, maximumDepth: 3)
        XCTAssertEqual(chain.map(\.name), ["level4", "level5", "level6"])
    }

    /// NO DECLARATION IS NOT A FAILURE — the measured line still stands on
    /// its own, and dropping it because the inference found nothing would
    /// throw away the half that was never a guess.
    func testAPrefixWithNoDeclarationsStillReportsTheLine() {
        let reading = CodeCursorScope.reading(
            prefix: "// notes\n// more notes\n", excerpt: "x", patterns: patterns)
        XCTAssertTrue(reading.chain.isEmpty)
        XCTAssertEqual(CodeCursorScope.scopeLine(reading), "Cursor at line 3")
    }

    func testTheScopeLineNamesTheChainAndTheLine() {
        let reading = CodeCursorScope.Reading(
            line: 142, chain: ["Ledger", "record"], excerpt: "")
        XCTAssertEqual(
            CodeCursorScope.scopeLine(reading),
            "Cursor scope: Ledger → record (line 142)")
    }

    func testTheContentPutsTheScopeLineAboveTheExcerpt() {
        let reading = CodeCursorScope.Reading(
            line: 3, chain: ["Ledger"], excerpt: "\n    let total = 0\n")
        XCTAssertEqual(
            CodeCursorScope.content(reading),
            "Cursor scope: Ledger (line 3)\n    let total = 0")
    }

    // MARK: - The window around the caret

    func testTheWindowIsCentredOnTheCaret() {
        let window = CodeCursorScope.window(around: 500, total: 1000, budget: 100)
        XCTAssertEqual(window, 450..<550)
    }

    /// A CARET NEAR THE START SPENDS THE WHOLE BUDGET FORWARDS rather than
    /// losing half of it to text that does not exist.
    func testTheWindowAtTheStartStillSpendsTheWholeBudget() {
        let window = CodeCursorScope.window(around: 10, total: 1000, budget: 100)
        XCTAssertEqual(window, 0..<100)
    }

    func testTheWindowAtTheEndStillSpendsTheWholeBudget() {
        let window = CodeCursorScope.window(around: 995, total: 1000, budget: 100)
        XCTAssertEqual(window, 900..<1000)
    }

    func testAWindowWiderThanTheDocumentIsTheWholeDocument() {
        XCTAssertEqual(
            CodeCursorScope.window(around: 5, total: 20, budget: 500), 0..<20)
    }

    func testAnEmptyDocumentYieldsAnEmptyWindow() {
        XCTAssertTrue(CodeCursorScope.window(around: 0, total: 0, budget: 500).isEmpty)
    }

    // MARK: - Snapping to whole lines

    func testACutWindowLosesItsBrokenFirstAndLastLines() {
        let snapped = CodeCursorScope.snapped(
            "ord() {\n    let a = 1\n    let b = 2\n    let c",
            cutAtStart: true, cutAtEnd: true)
        XCTAssertEqual(snapped, "    let a = 1\n    let b = 2")
    }

    /// AN UNCUT END KEEPS ITS LINE. A window that reaches the top of the file
    /// starts on a real line, and eating it would lose the very declaration
    /// the caret sits under.
    func testAnUncutStartKeepsItsFirstLine() {
        let snapped = CodeCursorScope.snapped(
            "struct Ledger {\n    let a = 1\n    let c",
            cutAtStart: false, cutAtEnd: true)
        XCTAssertEqual(snapped, "struct Ledger {\n    let a = 1")
    }

    /// A TRIM THAT WOULD EMPTY THE EXCERPT IS NOT TAKEN — a partial line is
    /// worth more than nothing at all.
    func testASingleBrokenLineSurvivesRatherThanVanishing() {
        let snapped = CodeCursorScope.snapped(
            "middle of one very long line", cutAtStart: true, cutAtEnd: true)
        XCTAssertEqual(snapped, "middle of one very long line")
    }
}

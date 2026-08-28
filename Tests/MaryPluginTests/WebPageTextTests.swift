//
//  WebPageTextTests.swift
//  MaryPluginTests
//
//  Pins `WebPageText.readCore` — the rules that turn a page's accessibility
//  tree into the words a person would read — against synthetic trees, with no
//  browser and no AX IPC.
//
//  Every rule here has a failure that LOOKS like success, which is why they
//  are worth pinning rather than eyeballing: breadth-first order returns the
//  whole page in the wrong sequence, a missing dedup returns every link
//  twice, a parent that does not defer to its text child returns each
//  sentence twice, and a silent truncation returns half a page presented as
//  the page. None of those throw.
//

import XCTest
@testable import MaryPlugin

final class WebPageTextTests: XCTestCase {

    private struct Node {
        var role: String
        var text: String?
        var children: [Node] = []
    }

    private func read(_ root: Node, byteLimit: Int = 8000) -> WebPageText.Reading {
        WebPageText.readCore(
            from: root,
            children: { $0.children },
            role: { $0.role },
            text: { $0.text },
            byteLimit: byteLimit)
    }

    private func text(_ value: String) -> Node { Node(role: "AXStaticText", text: value) }
    private func group(_ children: [Node]) -> Node {
        Node(role: "AXGroup", text: nil, children: children)
    }

    // MARK: - Order

    /// DOCUMENT ORDER, which is what makes the result prose rather than an
    /// inventory. Breadth-first would return "Title, Footer, Body" here —
    /// every word present, the meaning gone.
    func testReadsInDocumentOrderNotBreadthFirst() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            Node(role: "AXHeading", text: "Title"),
            group([text("Body one"), text("Body two")]),
            text("Footer"),
        ])
        XCTAssertEqual(read(page).text, "Title\nBody one\nBody two\nFooter")
    }

    /// The stack walk pushes children reversed precisely so this holds. Read
    /// unreversed, a page comes back with every element's children in
    /// right-to-left order — which still looks like a working reader.
    func testSiblingsKeepTheirOrder() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            text("one"), text("two"), text("three"), text("four"),
        ])
        XCTAssertEqual(read(page).text, "one\ntwo\nthree\nfour")
    }

    // MARK: - What contributes

    /// A link wrapping its own static text says the same thing twice. The
    /// child is the more specific reading, so the parent stands down.
    func testAParentWithATextChildDefersToIt() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            Node(role: "AXLink", text: "Sign in", children: [text("Sign in")]),
        ])
        let reading = read(page)
        XCTAssertEqual(reading.text, "Sign in")
        XCTAssertEqual(reading.contributingNodes, 1)
    }

    /// But a link with no text child is the only one who can say it.
    func testAParentWithNoTextChildStillContributes() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            Node(role: "AXLink", text: "Sign in", children: [Node(role: "AXImage", text: nil)]),
        ])
        XCTAssertEqual(read(page).text, "Sign in")
    }

    /// Layout roles carry no words. A collector that took every node's every
    /// string would return the page's structure as if it were its content.
    func testLayoutRolesContributeNothingOfTheirOwn() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            Node(role: "AXGroup", text: "wrapper label", children: [text("real content")]),
        ])
        XCTAssertEqual(read(page).text, "real content")
    }

    /// A page says its nav labels in a header, a footer and a skip link. It
    /// says each of them once.
    func testRepeatedLinesAreSaidOnce() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            text("Home"), text("About"), text("Home"), text("Contact"), text("About"),
        ])
        XCTAssertEqual(read(page).text, "Home\nAbout\nContact")
    }

    func testWhitespaceOnlyNodesAreNotLines() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            text("  "), text("\n\t"), text("real"),
        ])
        XCTAssertEqual(read(page).text, "real")
    }

    // MARK: - Budgets

    /// TRUNCATION IS PART OF THE ANSWER. Half a page presented as the page is
    /// a wrong answer wearing a right one's clothes, so the flag rides along
    /// and a caller can say "the first part of".
    func testByteLimitTruncatesAndSaysSo() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            text("aaaa"), text("bbbb"), text("cccc"),
        ])
        // "aaaa\n" and "bbbb\n" cost five bytes each; the third does not fit.
        let reading = read(page, byteLimit: 10)
        XCTAssertEqual(reading.text, "aaaa\nbbbb")
        XCTAssertTrue(reading.truncated)
    }

    func testAPageInsideTheBudgetIsNotMarkedTruncated() {
        let page = Node(role: "AXWebArea", text: nil, children: [text("short")])
        let reading = read(page)
        XCTAssertFalse(reading.truncated)
        XCTAssertEqual(reading.contributingNodes, 1)
    }

    func testNodeBudgetTruncatesAWideTree() {
        let wide = (0..<(WebPageText.budget.maxNodes + 50)).map { text("line \($0)") }
        let reading = read(Node(role: "AXWebArea", text: nil, children: wide))
        XCTAssertTrue(reading.truncated)
        XCTAssertLessThanOrEqual(reading.contributingNodes, WebPageText.budget.maxNodes)
    }

    /// Depth is a limit on descending, not on reading: a node AT the limit
    /// still speaks, its children do not. Same arithmetic as AXTreeWalker's.
    func testDepthLimitStopsDescentButReadsTheNodeItStopsAt() {
        // The web area is depth 0, so the node that sits exactly AT the limit
        // needs `maxDepth - 1` groups above it. Its own child is one past.
        var node = Node(
            role: "AXStaticText", text: "at the limit", children: [text("one past")])
        for _ in 1..<WebPageText.budget.maxDepth {
            node = Node(role: "AXGroup", text: nil, children: [node])
        }
        let reading = read(Node(role: "AXWebArea", text: nil, children: [node]))
        XCTAssertTrue(reading.text.contains("at the limit"))
        XCTAssertFalse(reading.text.contains("one past"))
    }

    // MARK: - Empty

    /// A page with a tree and no words is a REAL state — a canvas app, or a
    /// tree that has not filled in — and it is not the same as no page. The
    /// caller tells them apart because `read(inApp:)` returns nil for the
    /// second; this pins that the first is an empty reading, not a nil.
    func testAPageWithNoWordsReadsEmptyRatherThanFailing() {
        let page = Node(role: "AXWebArea", text: nil, children: [
            Node(role: "AXImage", text: nil), group([]),
        ])
        let reading = read(page)
        XCTAssertEqual(reading.text, "")
        XCTAssertEqual(reading.contributingNodes, 0)
        XCTAssertFalse(reading.truncated)
    }
}

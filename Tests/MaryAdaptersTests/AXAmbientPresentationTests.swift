//
//  AXAmbientPresentationTests.swift
//  BonniePluginTests
//
//  Pins the rows-and-lines model Clyde lays out: which rows self-suppress,
//  the "—" convention for a missing value inside a present row, the roster
//  line format and its stable ids, and the mechanical role humanization.
//

import CoreGraphics
import Foundation
import XCTest
@testable import MaryAdapters

final class AXAmbientPresentationTests: XCTestCase {

    private func context(
        window: Bool = true,
        focused: Bool = false,
        webContentHost: Bool = false,
        buttons: [String] = ["Save"]
    ) -> AXAmbientContext {
        let ids = AXIDVendor()
        var children = buttons.enumerated().map { index, label in
            AXSnapshotTestSupport.node(
                ids, role: "AXButton", label: label,
                frame: CGRect(x: 10 + 100 * CGFloat(index), y: 10, width: 80, height: 24),
                category: .interactive)
        }
        if focused {
            children.append(AXSnapshotTestSupport.node(
                ids, role: "AXTextField", label: "Search",
                frame: CGRect(x: 10, y: 50, width: 120, height: 22),
                category: .interactive, isFocused: true))
        }
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", category: .container, children: children)
        let windows = window
            ? [AXSnapshotTestSupport.window(
                ids, title: "Document",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600), root: root)]
            : []
        return AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app(windows),
            scope: .actionable, limit: AXElementRoster.publishedLimit,
            webContentHost: webContentHost,
            observersCovered: nil, observersTotal: nil)
    }

    // MARK: - Summary rows

    func testSummaryAlwaysNamesWindowAndElements() {
        let rows = AXAmbientPresentation.summaryRows(for: context())
        XCTAssertEqual(rows.first?.label, "Active window")
        XCTAssertEqual(rows.first?.value, "Document")
        XCTAssertEqual(rows[1].label, "Elements")
        XCTAssertEqual(rows[1].value, "1 actionable")
    }

    func testMissingWindowRendersAsDashNeverBlank() {
        let rows = AXAmbientPresentation.summaryRows(for: context(window: false))
        XCTAssertEqual(rows.first?.value, "—")
    }

    func testQuietLanesSelfSuppress() {
        let labels = AXAmbientPresentation.summaryRows(for: context()).map(\.label)
        XCTAssertFalse(labels.contains("Focused"))
        XCTAssertFalse(labels.contains("Web"))
        XCTAssertFalse(labels.contains("Scripted"))
    }

    func testHeaderWindowLineCarriesCounts() {
        let ids = AXIDVendor()
        let windows = [
            AXSnapshotTestSupport.window(
                ids, title: "Front",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            AXSnapshotTestSupport.window(ids, title: "Back", isMinimized: true),
            AXSnapshotTestSupport.window(ids, title: "Third"),
        ]
        let context = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app(windows))
        let rows = AXAmbientPresentation.headerRows(for: context)
        let window = rows.first { $0.label == "Window" }
        XCTAssertEqual(window?.value, "\"Front\" — front of 3, 1 minimized")
    }

    func testHeaderCaptureLineNamesTruncation() {
        var sample = context()
        sample.capture.isTruncated = true
        let rows = AXAmbientPresentation.headerRows(for: sample)
        let capture = rows.first { $0.label == "Capture" }
        XCTAssertTrue(capture?.value.contains("nodes") ?? false)
        XCTAssertTrue(capture?.value.hasSuffix("truncated") ?? false)
    }

    func testObserversRowOnlyWhenMeasured() {
        var sample = context()
        XCTAssertFalse(AXAmbientPresentation.headerRows(for: sample)
            .contains { $0.label == "Observers" })
        sample.capture.observersCovered = 3
        sample.capture.observersTotal = 5
        let row = AXAmbientPresentation.headerRows(for: sample)
            .first { $0.label == "Observers" }
        XCTAssertEqual(row?.value, "3/5")
    }

    // MARK: - Element lines

    func testElementLinesFollowOrdinalOrderWithStableIDs() {
        let sample = context(buttons: ["Save", "Cancel"])
        let lines = AXAmbientPresentation.elementLines(for: sample)
        XCTAssertEqual(lines.map(\.ordinal), [1, 2])
        XCTAssertEqual(lines.map(\.id), sample.elements.map(\.id.raw))
        XCTAssertEqual(lines.first?.text, "1 · control · Save")
        XCTAssertNil(lines.first?.trail)
    }

    func testElementLineTrailJoins() {
        let ids = AXIDVendor()
        let inner = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Play",
            frame: CGRect(x: 10, y: 10, width: 40, height: 20),
            category: .interactive)
        let sidebar = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", label: "Sidebar",
            frame: CGRect(x: 0, y: 0, width: 200, height: 600),
            category: .container,
            children: [AXSnapshotTestSupport.node(
                ids, role: "AXGroup", label: "Recents",
                frame: CGRect(x: 0, y: 0, width: 200, height: 300),
                category: .container, children: [inner])])
        let snapshot = AXSnapshotTestSupport.app([
            AXSnapshotTestSupport.window(
                ids, title: "Window",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600), root: sidebar)
        ])
        let lines = AXAmbientPresentation.elementLines(
            for: AXAmbientContext(snapshot: snapshot))
        XCTAssertEqual(lines.first?.trail, "Sidebar › Recents")
    }

    func testFocusedLineNilWhenNothingClaimsFocus() {
        XCTAssertNil(AXAmbientPresentation.focusedLine(for: context()))
        XCTAssertEqual(
            AXAmbientPresentation.focusedLine(for: context(focused: true)),
            "text field 'Search' (AXTextField)")
    }

    // MARK: - Words

    func testRoleWordHumanizesMechanically() {
        XCTAssertEqual(AXAmbientPresentation.roleWord("AXTextField"), "text field")
        XCTAssertEqual(AXAmbientPresentation.roleWord("AXButton"), "button")
        XCTAssertEqual(AXAmbientPresentation.roleWord("AXWebArea"), "web area")
        XCTAssertEqual(AXAmbientPresentation.roleWord("MaryScripted"), "scripted")
    }

    func testLongTitlesElide() {
        let long = String(repeating: "a", count: 80)
        let elided = AXAmbientPresentation.elided(long)
        XCTAssertEqual(elided.count, AXAmbientPresentation.summaryTitleCap)
        XCTAssertTrue(elided.hasSuffix("…"))
    }
}

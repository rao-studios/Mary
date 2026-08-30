//
//  AXAmbientContextTests.swift
//  BonniePluginTests
//
//  Pins the ambient artifact's derivation: totality over empty/minimized
//  snapshots, the WindowScope.front semantics for the active window, the
//  focus scan, stats folding into the lanes (and the nil-lane honesty —
//  silence never claims absence), and the timing-insensitive equality that
//  lets consumers skip republishing an unchanged screen.
//

import CoreGraphics
import Foundation
import XCTest
@testable import MaryPlugin

final class AXAmbientContextTests: XCTestCase {

    private func window(
        _ ids: AXIDVendor, title: String = "Window",
        isMinimized: Bool = false, isMain: Bool = false,
        root: AXNodeSnapshot? = nil
    ) -> AXWindowSnapshot {
        AXSnapshotTestSupport.window(
            ids, title: title, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMain: isMain, isMinimized: isMinimized, root: root)
    }

    private func button(
        _ ids: AXIDVendor, label: String, isFocused: Bool = false
    ) -> AXNodeSnapshot {
        AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: label,
            frame: CGRect(x: 10, y: 10, width: 80, height: 24),
            category: .interactive, isFocused: isFocused)
    }

    // MARK: - Totality

    func testActiveWindowSkipsMinimizedFront() {
        let ids = AXIDVendor()
        let minimized = window(ids, title: "Hidden", isMinimized: true)
        let visible = window(ids, title: "Front", root: button(ids, label: "Go"))
        let context = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app([minimized, visible]))
        XCTAssertEqual(context.activeWindow?.title, "Front")
        XCTAssertEqual(context.windowCount, 2)
        XCTAssertEqual(context.minimizedCount, 1)
    }

    func testAllWindowsMinimizedMeansNoActiveWindowButCountsSurvive() {
        let ids = AXIDVendor()
        let first = window(ids, title: "A", isMinimized: true)
        let second = window(ids, title: "B", isMinimized: true)
        let context = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app([first, second]))
        XCTAssertNil(context.activeWindow)
        XCTAssertEqual(context.windowCount, 2)
        XCTAssertEqual(context.minimizedCount, 2)
        XCTAssertTrue(context.elements.isEmpty)
    }

    // MARK: - Roster delegation

    func testElementsMatchRosterForTheSameSnapshot() {
        let ids = AXIDVendor()
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", category: .container,
            children: [button(ids, label: "Save"), button(ids, label: "Cancel")])
        let snapshot = AXSnapshotTestSupport.app([window(ids, root: root)])
        let context = AXAmbientContext(snapshot: snapshot)
        let roster = AXElementRoster.elements(
            in: snapshot, scope: AXAmbientContext.ambientScope, windows: .front)
        XCTAssertEqual(context.elements, roster)
        XCTAssertEqual(context.scope, AXAmbientContext.ambientScope)
        XCTAssertFalse(context.elements.isEmpty)
    }

    /// The published scope is `.all` on purpose — a surface is what is ON
    /// SCREEN, not only what can be pressed, and the affordance slate
    /// derived from the same walk needs the roles `.actionable` excludes.
    /// Pinned because a drift here silently changes what every ambient lane
    /// holds.
    func testTheAmbientScopeIsAll() {
        XCTAssertEqual(AXAmbientContext.ambientScope, .all)
    }

    func testScopeAndLimitAreHonored() {
        let ids = AXIDVendor()
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", category: .container,
            children: (1...5).map { button(ids, label: "Button \($0)") })
        let snapshot = AXSnapshotTestSupport.app([window(ids, root: root)])
        let context = AXAmbientContext(snapshot: snapshot, limit: 2)
        XCTAssertEqual(context.elements.count, 2)
    }

    // MARK: - Focus

    func testFocusedElementFoundInActiveWindow() {
        let ids = AXIDVendor()
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", category: .container,
            children: [
                button(ids, label: "Plain"),
                button(ids, label: "Chosen", isFocused: true),
            ])
        let context = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app([window(ids, root: root)]))
        XCTAssertEqual(context.focused?.label, "Chosen")
        XCTAssertEqual(context.focused?.role, "AXButton")
    }

    func testFocusFallsBackToABackgroundWindow() {
        let ids = AXIDVendor()
        let front = window(ids, title: "Front", root: button(ids, label: "Idle"))
        let palette = window(
            ids, title: "Palette",
            root: AXSnapshotTestSupport.node(
                ids, role: "AXTextField", label: "Search",
                frame: CGRect(x: 0, y: 0, width: 120, height: 22),
                category: .interactive, isFocused: true))
        let context = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app([front, palette]))
        XCTAssertEqual(context.focused?.label, "Search")
    }

    func testNoFocusClaimIsNil() {
        let ids = AXIDVendor()
        let context = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app(
                [window(ids, root: button(ids, label: "Idle"))]),
)
        XCTAssertNil(context.focused)
    }

    // MARK: - Stats folding

    func testEqualityIgnoresCaptureTiming() {
        let first = AXIDVendor()
        let second = AXIDVendor()
        func snapshot(_ ids: AXIDVendor, at date: Date, cost: Duration) -> AXAppSnapshot {
            var app = AXSnapshotTestSupport.app(
                [window(ids, root: button(ids, label: "Save"))])
            app.capturedAt = date
            app.walkDuration = cost
            return app
        }
        let early = AXAmbientContext(
            snapshot: snapshot(first, at: Date(timeIntervalSince1970: 100),
                               cost: .milliseconds(3)),
)
        let late = AXAmbientContext(
            snapshot: snapshot(second, at: Date(timeIntervalSince1970: 900),
                               cost: .milliseconds(70)),
)
        XCTAssertEqual(early, late)
    }

    func testEqualityStillSeesContentChange() {
        let first = AXIDVendor()
        let second = AXIDVendor()
        let one = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app(
                [window(first, root: button(first, label: "Save"))]),
)
        let other = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app(
                [window(second, root: button(second, label: "Delete"))]),
)
        XCTAssertNotEqual(one, other)
    }

    // MARK: - Capture honesty

    func testTruncationFoldsAcrossWindows() {
        let ids = AXIDVendor()
        var truncated = window(ids, title: "Heavy")
        truncated.isTruncated = true
        let context = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app([window(ids, title: "Light"), truncated]),
)
        XCTAssertTrue(context.capture.isTruncated)
    }
}

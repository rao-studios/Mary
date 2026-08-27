//
//  AXSnapshotModelTests.swift
//  BonniePluginTests
//
//  Pins the pure-value snapshot model's equality and subtree-count
//  short-circuit — what `AXRefreshPolicy`'s unchanged-snapshot backoff
//  actually compares. No AX IPC: every node is built via `AXNodeID(raw:)`.
//

import XCTest
@testable import MaryAdapters

final class AXSnapshotModelTests: XCTestCase {

    private func node(
        _ raw: UInt, category: AXNodeCategory = .other, frame: CGRect? = nil,
        children: [AXNodeSnapshot] = []
    ) -> AXNodeSnapshot {
        AXNodeSnapshot(
            id: AXNodeID(raw: raw), role: "AXGroup", frame: frame,
            category: category, children: children)
    }

    private func app(_ windows: [AXWindowSnapshot], pid: pid_t = 1) -> AXAppSnapshot {
        AXAppSnapshot(
            pid: pid, bundleID: "com.example.app", appName: "Example",
            windows: windows, capturedAt: Date(), walkDuration: .zero, nodeCount: 0)
    }

    // MARK: - AXNodeID

    func testNodeIDHashingUsesTheRawValue() {
        XCTAssertEqual(AXNodeID(raw: 5), AXNodeID(raw: 5))
        XCTAssertNotEqual(AXNodeID(raw: 5), AXNodeID(raw: 6))
        var set: Set<AXNodeID> = []
        set.insert(AXNodeID(raw: 1))
        set.insert(AXNodeID(raw: 1))
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - subtreeCount short-circuit

    func testSubtreeCountIsSelfPlusAllDescendants() {
        let leafA = node(1)
        let leafB = node(2)
        let mid = node(3, children: [leafA, leafB])
        let root = node(0, children: [mid])
        XCTAssertEqual(root.subtreeCount, 4)
        XCTAssertEqual(mid.subtreeCount, 3)
        XCTAssertEqual(leafA.subtreeCount, 1)
    }

    // MARK: - Changed/unchanged detection

    func testIdenticalSnapshotsAreEqualIgnoringCaptureTiming() {
        let windowA = AXWindowSnapshot(
            id: AXNodeID(raw: 1), title: "Untitled", frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            root: node(10))
        let first = AXAppSnapshot(
            pid: 1, bundleID: "com.example.app", appName: "Example",
            windows: [windowA], capturedAt: Date(), walkDuration: .zero, nodeCount: 2)
        let second = AXAppSnapshot(
            pid: 1, bundleID: "com.example.app", appName: "Example",
            windows: [windowA], capturedAt: Date().addingTimeInterval(5),
            walkDuration: .seconds(1), nodeCount: 2)
        XCTAssertEqual(first, second)
    }

    func testASingleChangedFrameMakesSnapshotsUnequal() {
        let windowA = AXWindowSnapshot(
            id: AXNodeID(raw: 1), title: "Untitled",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10), root: node(10))
        let windowB = AXWindowSnapshot(
            id: AXNodeID(raw: 1), title: "Untitled",
            frame: CGRect(x: 5, y: 0, width: 10, height: 10), root: node(10))
        XCTAssertNotEqual(app([windowA]), app([windowB]))
    }

    func testDifferentWindowCountsAreUnequal() {
        let windowA = AXWindowSnapshot(id: AXNodeID(raw: 1), title: "A", frame: nil)
        let windowB = AXWindowSnapshot(id: AXNodeID(raw: 2), title: "B", frame: nil)
        XCTAssertNotEqual(app([windowA]), app([windowA, windowB]))
    }
}

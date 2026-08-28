//
//  AXHitTestTests.swift
//  BonniePluginTests
//
//  Pins "which element is at this point" — smallest-area-wins ranking, the
//  window-as-fallback-target behavior, and the size floor that keeps a
//  screen-reader-only announcer node (measured live in GitHub Desktop,
//  1×1 points) from ever winning a hit test. Pure: synthetic snapshots, no
//  live AX, no Clyde.
//

import CoreGraphics
import Foundation
import XCTest
@testable import MaryPlugin

final class AXHitTestTests: XCTestCase {

    private var nextRaw: UInt = 1
    private func id() -> AXNodeID { defer { nextRaw += 1 }; return AXNodeID(raw: nextRaw) }

    private func node(
        _ frame: CGRect?, label: String? = nil, role: String = "AXGroup",
        _ children: [AXNodeSnapshot] = []
    ) -> AXNodeSnapshot {
        AXNodeSnapshot(
            id: id(), role: role, label: label, frame: frame, category: .container,
            children: children)
    }

    private func snapshot(windowFrame: CGRect, title: String = "Window", root: AXNodeSnapshot?) -> AXAppSnapshot {
        AXAppSnapshot(
            pid: 1, bundleID: "com.example.app", appName: "Example",
            windows: [AXWindowSnapshot(id: id(), title: title, frame: windowFrame, root: root)],
            capturedAt: Date(), walkDuration: .zero, nodeCount: 1)
    }

    // MARK: - Smallest area wins

    func testTheSmallestContainingFrameWins() {
        let inner = node(CGRect(x: 40, y: 40, width: 20, height: 20), label: "inner")
        let outer = node(CGRect(x: 0, y: 0, width: 100, height: 100), label: "outer", [inner])
        let found = AXHitTest.target(
            in: snapshot(windowFrame: CGRect(x: 0, y: 0, width: 200, height: 200), root: outer),
            at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(found?.label, "inner")
    }

    /// Real AX data does not always nest cleanly — a child can report a
    /// frame extending past its parent's. Area ranking (not recursion
    /// order) is what keeps the answer right anyway.
    func testAreaRankingSurvivesAMisnestedChild() {
        let overflowing = node(CGRect(x: -10, y: -10, width: 300, height: 300), label: "overflowing")
        let tighter = node(CGRect(x: 0, y: 0, width: 100, height: 100), label: "tighter", [overflowing])
        let found = AXHitTest.target(
            in: snapshot(windowFrame: CGRect(x: -50, y: -50, width: 400, height: 400), root: tighter),
            at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(found?.label, "tighter", "the geometrically smaller frame wins regardless of nesting")
    }

    // MARK: - Windows as fallback targets

    func testAnEmptyWindowBackgroundResolvesToTheWindow() {
        let content = node(CGRect(x: 10, y: 10, width: 20, height: 20), label: "content")
        let found = AXHitTest.target(
            in: snapshot(windowFrame: CGRect(x: 0, y: 0, width: 200, height: 200), root: content),
            at: CGPoint(x: 150, y: 150))
        XCTAssertTrue(found?.isWindow == true)
    }

    func testContentInsideTheWindowOutranksTheWindowItself() {
        let content = node(CGRect(x: 10, y: 10, width: 20, height: 20), label: "content")
        let found = AXHitTest.target(
            in: snapshot(windowFrame: CGRect(x: 0, y: 0, width: 200, height: 200), root: content),
            at: CGPoint(x: 15, y: 15))
        XCTAssertEqual(found?.label, "content")
        XCTAssertFalse(found?.isWindow == true)
    }

    func testAnUntitledWindowFallsBackToAPlaceholderLabel() {
        let found = AXHitTest.target(
            in: snapshot(windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100), title: "", root: nil),
            at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(found?.label, "Window")
    }

    // MARK: - The size floor

    /// Measured live: GitHub Desktop reports a real 1×1-point frame for a
    /// screen-reader-only announcer. It must never win — a hit test landing
    /// on it should fall through to whatever real content (or the window)
    /// is actually there.
    func testATinyAnnouncerNodeNeverWinsEvenThoughItContainsThePoint() {
        let announcer = node(CGRect(x: 50, y: 50, width: 1, height: 1), label: "fetch complete")
        let content = node(CGRect(x: 0, y: 0, width: 200, height: 200), label: "content", [announcer])
        let found = AXHitTest.target(
            in: snapshot(windowFrame: CGRect(x: 0, y: 0, width: 200, height: 200), root: content),
            at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(found?.label, "content", "the announcer must be skipped, not chosen")
    }

    func testExactlyAtTheFloorIsUsableJustBelowIsNot() {
        let atFloor = node(
            CGRect(x: 0, y: 0, width: AXHitTest.minimumExtent, height: AXHitTest.minimumExtent),
            label: "at-floor")
        let belowFloor = node(
            CGRect(x: 0, y: 0, width: AXHitTest.minimumExtent - 0.5, height: AXHitTest.minimumExtent),
            label: "below-floor")
        XCTAssertEqual(
            AXHitTest.target(
                in: snapshot(windowFrame: CGRect(x: 0, y: 0, width: 10, height: 10), root: atFloor),
                at: .zero)?.label,
            "at-floor")
        XCTAssertNil(
            AXHitTest.target(
                in: snapshot(windowFrame: .zero, root: belowFloor), at: .zero))
    }

    // MARK: - Nothing there

    func testAPointOutsideEverythingResolvesToNothing() {
        let content = node(CGRect(x: 0, y: 0, width: 10, height: 10), label: "content")
        let found = AXHitTest.target(
            in: snapshot(windowFrame: CGRect(x: 0, y: 0, width: 10, height: 10), root: content),
            at: CGPoint(x: 500, y: 500))
        XCTAssertNil(found)
    }

    func testANodeWithNoFrameIsNeverAConsideredCandidate() {
        let ghost = node(nil, label: "ghost")
        let content = node(CGRect(x: 0, y: 0, width: 100, height: 100), label: "content", [ghost])
        let found = AXHitTest.target(
            in: snapshot(windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100), root: content),
            at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(found?.label, "content")
    }

    // MARK: - trailDepth — the outer-container / infinite-loop fix

    private let outer = CGRect(x: 0, y: 0, width: 300, height: 300)
    private let middle = CGRect(x: 50, y: 50, width: 200, height: 200)
    private let inner = CGRect(x: 100, y: 100, width: 50, height: 50)

    func testDrillingDeeperPopsNothing() {
        // The ordinary case: target is a genuine descendant of the current
        // focus — every existing level survives, the caller just appends.
        XCTAssertEqual(AXHitTest.trailDepth([outer], navigatingTo: middle), 1)
        XCTAssertEqual(AXHitTest.trailDepth([outer, middle], navigatingTo: inner), 2)
    }

    /// The exact bug: zoomed into `inner` (trail = outer, middle, inner),
    /// tapping the container one level up must land the caller's
    /// `prefix(trailDepth) + [target]` at [outer, middle] — depth 1 kept,
    /// plus the appended `middle` itself, not [outer, middle, inner,
    /// middle] appending backwards.
    func testTappingTheImmediateOuterContainerPopsOneLevel() {
        XCTAssertEqual(AXHitTest.trailDepth([outer, middle, inner], navigatingTo: middle), 1)
    }

    /// A single tap can skip straight past an intermediate level (the
    /// smallest-area rule means `middle` was never separately visited) —
    /// popping must still land correctly on what target actually contains:
    /// `outer` contains everything, including itself, so nothing survives
    /// and the caller's append lands at [outer] alone.
    func testTappingAContainerSeveralLevelsUpPopsAllOfThem() {
        XCTAssertEqual(AXHitTest.trailDepth([outer, middle, inner], navigatingTo: outer), 0)
    }

    /// The reported failure mode: alternating taps between two already-
    /// visited levels must never grow the trail — each step should settle
    /// at a small, bounded depth, not accumulate.
    func testAlternatingTapsBetweenTwoLevelsNeverGrowsTheTrail() {
        var trail = [outer]
        // → inner (descend)
        trail = Array(trail.prefix(AXHitTest.trailDepth(trail, navigatingTo: inner))) + [inner]
        XCTAssertEqual(trail, [outer, inner])
        // → outer again (the reported bug: this used to append, not pop)
        trail = Array(trail.prefix(AXHitTest.trailDepth(trail, navigatingTo: outer))) + [outer]
        XCTAssertEqual(trail, [outer])
        // → inner again
        trail = Array(trail.prefix(AXHitTest.trailDepth(trail, navigatingTo: inner))) + [inner]
        XCTAssertEqual(trail, [outer, inner])
        // → outer again — still bounded, not [outer, inner, outer, inner, …]
        trail = Array(trail.prefix(AXHitTest.trailDepth(trail, navigatingTo: outer))) + [outer]
        XCTAssertEqual(trail, [outer])
    }

    func testATargetContainingTheEntireTrailPopsAllOfIt() {
        let huge = CGRect(x: -1000, y: -1000, width: 3000, height: 3000)
        XCTAssertEqual(AXHitTest.trailDepth([outer, middle, inner], navigatingTo: huge), 0)
    }

    func testAnUnrelatedSiblingFrameThatDoesNotContainTheFocusPopsNothing() {
        let sibling = CGRect(x: 500, y: 500, width: 20, height: 20)
        XCTAssertEqual(AXHitTest.trailDepth([outer, middle], navigatingTo: sibling), 2)
    }

    func testAnEmptyTrailHasNothingToPop() {
        XCTAssertEqual(AXHitTest.trailDepth([], navigatingTo: outer), 0)
    }

    /// Re-tapping the exact same frame already at the top: self-containment
    /// means it pops itself along with the loop — harmless, since the
    /// caller re-appends it, netting to the same single entry.
    func testRetappingTheSameFrameNetsToOneEntry() {
        XCTAssertEqual(AXHitTest.trailDepth([outer, middle], navigatingTo: middle), 1)
    }

    // MARK: - Re-locating by id (the live-tracking lookup)

    func testFrameOfIDFindsAWindow() {
        let snap = snapshot(windowFrame: CGRect(x: 1, y: 2, width: 3, height: 4), root: nil)
        XCTAssertEqual(AXHitTest.frame(of: snap.windows[0].id, in: snap), snap.windows[0].frame)
    }

    func testFrameOfIDFindsANestedNode() {
        let target = node(CGRect(x: 7, y: 8, width: 9, height: 10), label: "target")
        let wrapper = node(CGRect(x: 0, y: 0, width: 100, height: 100), label: "wrapper", [target])
        let snap = snapshot(windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100), root: wrapper)
        XCTAssertEqual(AXHitTest.frame(of: target.id, in: snap), target.frame)
    }

    func testFrameOfIDAnswersNilWhenTheIDIsGone() {
        let snap = snapshot(windowFrame: CGRect(x: 0, y: 0, width: 10, height: 10), root: nil)
        XCTAssertNil(AXHitTest.frame(of: AXNodeID(raw: 999_999), in: snap))
    }
}

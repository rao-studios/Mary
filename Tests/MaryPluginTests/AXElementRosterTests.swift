//
//  AXElementRosterTests.swift
//  BonniePluginTests
//
//  Pins the snapshot lane's flattener: the reading-order comparator ported
//  from `PageElementReader.publish` (never unit-tested in the page lane
//  itself — this is the first place it is pinned directly), scope honesty,
//  geometry floors and window clipping, window scoping, the dedup pass, and
//  the metadata a resolver needs later (identity, container trail,
//  `isBackedByLiveAX`). Pure: synthetic snapshots, no live AX, no Clyde.
//

import CoreGraphics
import XCTest
@testable import MaryPlugin

final class AXElementRosterTests: XCTestCase {

    private typealias Candidate = AXElementRoster.Candidate

    private func candidate(
        label: String, frame: CGRect, category: AXNodeCategory = .interactive
    ) -> Candidate {
        Candidate(
            id: AXNodeID(raw: 1), role: "AXButton", subrole: nil, category: category,
            label: label, frame: frame, isEnabled: true, isFocused: false, containerTrail: [])
    }

    // MARK: - Reading order: the comparator, pinned for the first time

    func testLeftToRightWithinABand() {
        let left = candidate(label: "Left", frame: CGRect(x: 0, y: 10, width: 10, height: 10))
        let right = candidate(label: "Right", frame: CGRect(x: 100, y: 10, width: 10, height: 10))
        XCTAssertTrue(AXElementRoster.precedes(left, right))
        XCTAssertFalse(AXElementRoster.precedes(right, left))
    }

    /// `readingBandHeight` is 24: 23.9 and 24.1 fall in different bands
    /// (`floor(23.9/24) == 0`, `floor(24.1/24) == 1`) even though they are
    /// visually a fifth of a point apart.
    func testABandBoundarySplitsTwoAlmostTouchingElements() {
        let above = candidate(label: "Above", frame: CGRect(x: 500, y: 23.9, width: 1, height: 0))
        let below = candidate(label: "Below", frame: CGRect(x: 0, y: 24.1, width: 1, height: 0))
        XCTAssertTrue(AXElementRoster.precedes(above, below))
    }

    /// 30 and 40 both floor-divide by 24 to band 1 — they share a row even
    /// though they are 10 points apart vertically.
    func testTwoMidYsInTheSameBandAreOrderedByX() {
        let leftInBand = candidate(label: "A", frame: CGRect(x: 5, y: 30, width: 1, height: 0))
        let rightInBand = candidate(label: "B", frame: CGRect(x: 50, y: 40, width: 1, height: 0))
        XCTAssertTrue(AXElementRoster.precedes(leftInBand, rightInBand))
    }

    /// Band always outranks X: an earlier row's rightmost element still
    /// precedes a later row's leftmost one.
    func testAHigherBandWinsEvenWhenItIsTheRightmostElement() {
        let earlyRowFarRight = candidate(
            label: "EarlyRight", frame: CGRect(x: 1000, y: 10, width: 1, height: 0))
        let laterRowFarLeft = candidate(
            label: "LaterLeft", frame: CGRect(x: 0, y: 100, width: 1, height: 0))
        XCTAssertTrue(AXElementRoster.precedes(earlyRowFarRight, laterRowFarLeft))
    }

    /// Same band, same X: the label is the total-order tiebreak.
    func testABandAndXTieBreaksByLabel() {
        let a = candidate(label: "Apple", frame: CGRect(x: 10, y: 10, width: 1, height: 0))
        let z = candidate(label: "Zebra", frame: CGRect(x: 10, y: 10, width: 1, height: 0))
        XCTAssertTrue(AXElementRoster.precedes(a, z))
        XCTAssertFalse(AXElementRoster.precedes(z, a))
    }

    /// Ordinals are dense, 1-based, and reflect reading order — not the
    /// order children were attached in the tree.
    func testOrdinalsAreDenseAndOneBasedInReadingOrder() {
        let ids = AXIDVendor()
        let third = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Third",
            frame: CGRect(x: 0, y: 100, width: 20, height: 20), category: .interactive)
        let first = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "First",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let second = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Second",
            frame: CGRect(x: 0, y: 30, width: 20, height: 20), category: .interactive)
        // Attached out of reading order on purpose.
        let root = AXSnapshotTestSupport.node(
            ids, category: .container, children: [third, first, second])
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: root)
        let elements = AXElementRoster.elements(in: AXSnapshotTestSupport.app([window]))
        XCTAssertEqual(elements.map(\.label), ["First", "Second", "Third"])
        XCTAssertEqual(elements.map(\.ordinal), [1, 2, 3])
    }

    // MARK: - Scope honesty

    private func mixedRoot(_ ids: AXIDVendor) -> AXNodeSnapshot {
        let button = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Press",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let scripted = AXSnapshotTestSupport.node(
            ids, role: "BonnieScripted", label: "Slide 1",
            frame: CGRect(x: 0, y: 30, width: 20, height: 20), category: .scripted)
        let text = AXSnapshotTestSupport.node(
            ids, role: "AXStaticText", label: "Some words",
            frame: CGRect(x: 0, y: 60, width: 20, height: 20), category: .text)
        let sheet = AXSnapshotTestSupport.node(
            ids, role: "AXSheet", label: "Sheet",
            frame: CGRect(x: 0, y: 90, width: 20, height: 20), category: .window)
        return AXSnapshotTestSupport.node(
            ids, category: .container, children: [button, scripted, text, sheet])
    }

    func testActionableScopeCollectsOnlyInteractiveAndScripted() {
        let ids = AXIDVendor()
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: mixedRoot(ids))
        let elements = AXElementRoster.elements(
            in: AXSnapshotTestSupport.app([window]), scope: .actionable)
        XCTAssertEqual(Set(elements.map(\.label)), ["Press", "Slide 1"])
    }

    func testReadableScopeCollectsOnlyText() {
        let ids = AXIDVendor()
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: mixedRoot(ids))
        let elements = AXElementRoster.elements(
            in: AXSnapshotTestSupport.app([window]), scope: .readable)
        XCTAssertEqual(elements.map(\.label), ["Some words"])
    }

    func testAllScopeExcludesOnlyWindowCategoryNodes() {
        let ids = AXIDVendor()
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: mixedRoot(ids))
        let elements = AXElementRoster.elements(
            in: AXSnapshotTestSupport.app([window]), scope: .all)
        XCTAssertEqual(Set(elements.map(\.label)), ["Press", "Slide 1", "Some words"])
    }

    func testAnUnlabeledNodeNeverPublishesInAnyScope() {
        let ids = AXIDVendor()
        let unlabeled = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: nil,
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: unlabeled)
        XCTAssertTrue(
            AXElementRoster.elements(in: AXSnapshotTestSupport.app([window]), scope: .all).isEmpty)
    }

    func testANodeWithNoFrameNeverPublishes() {
        let ids = AXIDVendor()
        let ghost = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Ghost", frame: nil, category: .interactive)
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: ghost)
        XCTAssertTrue(
            AXElementRoster.elements(in: AXSnapshotTestSupport.app([window])).isEmpty)
    }

    // MARK: - Geometry

    func testTheEightPointInteractiveFloor() {
        let tooSmall = candidate(
            label: "Small", frame: CGRect(x: 0, y: 0, width: 7, height: 7), category: .interactive)
        let atFloor = candidate(
            label: "AtFloor", frame: CGRect(x: 0, y: 0, width: 8, height: 8), category: .interactive)
        XCTAssertFalse(AXElementRoster.hasActionableSize(
            tooSmall.frame, role: "AXButton", category: .interactive))
        XCTAssertTrue(AXElementRoster.hasActionableSize(
            atFloor.frame, role: "AXButton", category: .interactive))
    }

    /// MEASURED live on YouTube (see `PageElementReader`): a 1261×6 seek
    /// track must survive even though 6 is under the ordinary floor.
    func testAThinSemanticSliderSurvives() {
        XCTAssertTrue(AXElementRoster.hasActionableSize(
            CGRect(x: 0, y: 0, width: 1261, height: 6), role: "AXSlider", category: .interactive))
    }

    /// A 1×1 element (the GitHub Desktop aria-live announcer shape) is
    /// dropped even at the lower, non-interactive floor.
    func testAHairlineElementIsDroppedAtTheLowerFloor() {
        XCTAssertFalse(AXElementRoster.hasActionableSize(
            CGRect(x: 0, y: 0, width: 85, height: 1), role: "AXStaticText", category: .text))
    }

    func testAnElementPartiallyOutsideItsWindowIsClippedToTheVisiblePortion() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let measured = CGRect(x: 90, y: 90, width: 30, height: 30)
        let published = AXElementRoster.publishableFrame(
            measured: measured, window: window, role: "AXButton", category: .interactive)
        XCTAssertEqual(published, CGRect(x: 90, y: 90, width: 10, height: 10))
    }

    /// A range track only publishes while its whole span is inside the
    /// window — a partially-scrolled-off slider has no honest fraction.
    func testAPartiallyVisibleSliderIsDroppedEntirely() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let measured = CGRect(x: 90, y: 50, width: 30, height: 6)
        XCTAssertNil(AXElementRoster.publishableFrame(
            measured: measured, window: window, role: "AXSlider", category: .interactive))
    }

    func testANilWindowFrameLeavesTheElementUnclipped() {
        let measured = CGRect(x: 900, y: 900, width: 20, height: 20)
        let published = AXElementRoster.publishableFrame(
            measured: measured, window: nil, role: "AXButton", category: .interactive)
        XCTAssertEqual(published, measured)
    }

    // MARK: - Window scoping

    func testFrontWindowIsTheDefaultScope() {
        let ids = AXIDVendor()
        let front = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Front Button",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let back = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Back Button",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let frontWindow = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: front)
        let backWindow = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: back)
        let elements = AXElementRoster.elements(
            in: AXSnapshotTestSupport.app([frontWindow, backWindow]))
        XCTAssertEqual(elements.map(\.label), ["Front Button"])
    }

    /// Windows are a stronger grouping than geometry: the back window's
    /// content sits at a numerically SMALLER y than the front window's, and
    /// must still publish after it, not before.
    func testWindowsConcatenateFrontFirstWithContinuousOrdinals() {
        let ids = AXIDVendor()
        let frontContent = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Front",
            frame: CGRect(x: 0, y: 100, width: 20, height: 20), category: .interactive)
        let backContent = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Back",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let frontWindow = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: frontContent)
        let backWindow = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: backContent)
        let elements = AXElementRoster.elements(
            in: AXSnapshotTestSupport.app([frontWindow, backWindow]), windows: .all)
        XCTAssertEqual(elements.map(\.label), ["Front", "Back"])
        XCTAssertEqual(elements.map(\.ordinal), [1, 2])
    }

    func testMinimizedWindowsAreAlwaysExcluded() {
        let ids = AXIDVendor()
        let hidden = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Hidden",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let visible = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Visible",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let minimizedWindow = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200),
            isMinimized: true, root: hidden)
        let visibleWindow = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: visible)
        let app = AXSnapshotTestSupport.app([minimizedWindow, visibleWindow])
        XCTAssertEqual(
            AXElementRoster.elements(in: app, windows: .front).map(\.label), ["Visible"])
        XCTAssertEqual(
            AXElementRoster.elements(in: app, windows: .all).map(\.label), ["Visible"])
    }

    // MARK: - Dedup

    func testAContainerEchoingItsChildsLabelCollapsesToTheInteractiveChild() {
        let ids = AXIDVendor()
        let frame = CGRect(x: 0, y: 0, width: 50, height: 20)
        let button = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Save", frame: frame, category: .interactive)
        let container = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", label: "Save", frame: frame, category: .container,
            children: [button])
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: container)
        let elements = AXElementRoster.elements(
            in: AXSnapshotTestSupport.app([window]), scope: .all)
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.category, .interactive)
    }

    func testAnEqualRankTieIsBrokenByTheSmallerFrame() {
        let outer = candidate(label: "OK", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let inner = candidate(label: "OK", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let kept = AXElementRoster.deduplicated([outer, inner])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.frame, inner.frame)
    }

    func testTheSameLabelFarApartStaysTwoThings() {
        let here = candidate(label: "OK", frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let there = candidate(label: "OK", frame: CGRect(x: 500, y: 500, width: 20, height: 20))
        XCTAssertEqual(AXElementRoster.deduplicated([here, there]).count, 2)
    }

    /// Dedup runs per window, before the windows are concatenated — two
    /// different windows whose content happens to share a frame and a
    /// label are still two separate, real things.
    func testDedupNeverCollapsesAcrossWindows() {
        let ids = AXIDVendor()
        let frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        let firstOK = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "OK", frame: frame, category: .interactive)
        let secondOK = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "OK", frame: frame, category: .interactive)
        let windowA = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: firstOK)
        let windowB = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: secondOK)
        let elements = AXElementRoster.elements(
            in: AXSnapshotTestSupport.app([windowA, windowB]), windows: .all)
        XCTAssertEqual(elements.count, 2)
    }

    // MARK: - Metadata

    func testContainerTrailAndWindowIdentityAreCarried() {
        let ids = AXIDVendor()
        let button = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Open",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let files = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", label: "Files", category: .container, children: [button])
        let sidebar = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", label: "Sidebar", category: .container, children: [files])
        let window = AXSnapshotTestSupport.window(
            ids, title: "Finder", frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: sidebar)
        let app = AXSnapshotTestSupport.app([window], pid: 42, appName: "Finder")
        let elements = AXElementRoster.elements(in: app)
        let open = try! XCTUnwrap(elements.first)
        XCTAssertEqual(open.containerTrail, ["Sidebar", "Files"])
        XCTAssertEqual(open.windowID, window.id)
        XCTAssertEqual(open.windowTitle, "Finder")
        XCTAssertEqual(open.pid, 42)
        XCTAssertEqual(open.appName, "Finder")
    }

    func testContainerTrailIsCappedAtFourInnermostAncestors() {
        let ids = AXIDVendor()
        var node = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Deep",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        for depth in stride(from: 6, through: 1, by: -1) {
            node = AXSnapshotTestSupport.node(
                ids, role: "AXGroup", label: "Level\(depth)", category: .container,
                children: [node])
        }
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: node)
        let elements = AXElementRoster.elements(in: AXSnapshotTestSupport.app([window]))
        XCTAssertEqual(elements.first?.containerTrail, ["Level3", "Level4", "Level5", "Level6"])
    }

    func testScriptedElementsAreNotBackedByLiveAX() {
        let ids = AXIDVendor()
        let scripted = AXSnapshotTestSupport.node(
            ids, role: "BonnieScripted", label: "Slide 1",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .scripted)
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: scripted)
        let element = try! XCTUnwrap(
            AXElementRoster.elements(in: AXSnapshotTestSupport.app([window])).first)
        XCTAssertFalse(element.isBackedByLiveAX)
    }

    func testAWalkedInteractiveElementIsBackedByLiveAX() {
        let ids = AXIDVendor()
        let button = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Press",
            frame: CGRect(x: 0, y: 0, width: 20, height: 20), category: .interactive)
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: button)
        let element = try! XCTUnwrap(
            AXElementRoster.elements(in: AXSnapshotTestSupport.app([window])).first)
        XCTAssertTrue(element.isBackedByLiveAX)
    }

    func testTheLimitCutsAfterOrdering() {
        let ids = AXIDVendor()
        let children = (0..<5).map { index in
            AXSnapshotTestSupport.node(
                ids, role: "AXButton", label: "Row\(index)",
                frame: CGRect(x: 0, y: CGFloat(index) * 30, width: 20, height: 20),
                category: .interactive)
        }
        let root = AXSnapshotTestSupport.node(ids, category: .container, children: children)
        let window = AXSnapshotTestSupport.window(
            ids, frame: CGRect(x: 0, y: 0, width: 200, height: 200), root: root)
        let elements = AXElementRoster.elements(
            in: AXSnapshotTestSupport.app([window]), limit: 3)
        XCTAssertEqual(elements.map(\.label), ["Row0", "Row1", "Row2"])
        XCTAssertEqual(elements.map(\.ordinal), [1, 2, 3])
    }
}

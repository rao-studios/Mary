//
//  AXSnapshotBuildCoreTests.swift
//  BonniePluginTests
//
//  Pins `AXSnapshotBuilder.buildNodeCore` against synthetic graphs — the walk
//  that assembles every published snapshot, which until the generic-core
//  extraction was private, live-AX-only, and therefore entirely untested.
//
//  Two things are pinned here that nothing else can pin:
//
//    - PARITY. With `webAreaBudget: nil` the core must reproduce the legacy
//      arithmetic exactly — count-before-cap-check, a node AT maxDepth
//      visited with only its children withheld — the same off-by-one
//      `AXTreeWalkerTests` pins for the BFS walker. If these two ever
//      disagree, the builder and the walker have silently forked.
//    - THE IPC DIET. The builder's central claim is that most nodes cost a
//      role and a frame rather than the full attribute set. Counting closures
//      turn that claim into an assertion instead of a comment.
//

import CoreGraphics
import XCTest
@testable import MaryPlugin

final class AXSnapshotBuildCoreTests: XCTestCase {

    // MARK: - Synthetic tree

    private struct Node {
        var id: Int
        var role: String
        var children: [Node] = []
    }

    private var nextID = 0

    private func node(_ role: String, _ children: [Node] = []) -> Node {
        nextID += 1
        return Node(id: nextID, role: role, children: children)
    }

    /// Counts every attribute closure the walk invokes, so the diet is
    /// measurable rather than asserted in a comment.
    private final class Reads {
        var subrole = 0
        var label = 0
        var isEnabled = 0
        var isFocused = 0
        var frame = 0
        var contentSize = 0
        var recorded: [AXNodeID] = []
    }

    private func source(
        reads: Reads = Reads(), label: String? = nil
    ) -> AXSnapshotBuilder.AXNodeSource<Node> {
        .init(
            id: { AXNodeID(raw: UInt($0.id)) },
            role: { $0.role },
            subrole: { _ in reads.subrole += 1; return "AXSubrole" },
            rawLabel: { _ in reads.label += 1; return label },
            frame: { _ in reads.frame += 1; return CGRect(x: 0, y: 0, width: 10, height: 10) },
            isEnabled: { _ in reads.isEnabled += 1; return true },
            isFocused: { _ in reads.isFocused += 1; return false },
            children: { $0.children },
            record: { id, _ in reads.recorded.append(id) },
            contentSize: { _ in reads.contentSize += 1; return nil })
    }

    private func options(
        web: AXTreeWalker.Budget? = nil, labelCap: Int = 80
    ) -> AXSnapshotBuilder.Options {
        AXSnapshotBuilder.Options(labelCap: labelCap, webAreaBudget: web)
    }

    @discardableResult
    private func build(
        _ root: Node,
        native: AXTreeWalker.Budget,
        web: AXTreeWalker.Budget? = nil,
        labelCap: Int = 80,
        label: String? = nil,
        reads: Reads = Reads(),
        tallies: inout AXSnapshotBuilder.LaneTallies
    ) -> AXNodeSnapshot {
        AXSnapshotBuilder.buildNodeCore(
            from: root,
            lane: .native,
            depth: 0,
            source: source(reads: reads, label: label),
            options: options(web: web, labelCap: labelCap),
            budgets: .init(native: native, web: web),
            tallies: &tallies)
    }

    // MARK: - Parity with the legacy arithmetic (no web escalation)

    func testNodeCapVisitsExactlyMaxNodesAndFlagsTruncation() {
        // Root with 5 children, cap 3: root + two children are built, the
        // third child's turn trips the cap BEFORE it is visited.
        let root = node("AXWindow", (1...5).map { _ in node("AXButton") })
        var tallies = AXSnapshotBuilder.LaneTallies()
        let snapshot = build(root, native: .init(maxDepth: 10, maxNodes: 3), tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 3)
        XCTAssertTrue(tallies.native.truncated)
        XCTAssertEqual(snapshot.children.count, 2)
        XCTAssertEqual(snapshot.subtreeCount, 3)
    }

    func testUntruncatedWalkLeavesTheFlagClear() {
        let root = node("AXWindow", [node("AXButton"), node("AXButton")])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .init(maxDepth: 10, maxNodes: 100), tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 3)
        XCTAssertFalse(tallies.native.truncated)
    }

    func testNodeAtMaxDepthIsVisitedAndOnlyItsChildrenAreWithheld() {
        // A 4-node chain at depths 0..3, depth capped at 2.
        let root = node("AXWindow", [node("AXGroup", [node("AXGroup", [node("AXButton")])])])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .init(maxDepth: 2, maxNodes: 100), tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 3, "the node AT maxDepth is still visited")
        XCTAssertTrue(tallies.native.truncated, "its withheld children are a truncation")
    }

    func testDepthLimitWithNoChildrenToWithholdIsNotTruncation() {
        let root = node("AXWindow", [node("AXGroup", [node("AXButton")])])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .init(maxDepth: 2, maxNodes: 100), tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 3)
        XCTAssertFalse(tallies.native.truncated, "nothing was actually withheld")
    }

    func testWebAreaDoesNotEscalateWhenTheWebBudgetIsDisabled() {
        // The parity guarantee: with `webAreaBudget: nil` a page is walked on
        // the window's own budget, exactly as before the web lane existed.
        let root = node("AXWindow", [node("AXWebArea", [node("AXLink"), node("AXLink")])])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .init(maxDepth: 10, maxNodes: 100), web: nil, tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 4)
        XCTAssertEqual(tallies.web, AXSnapshotBuilder.WalkTally())
        XCTAssertEqual(tallies.webAreaCount, 1, "still COUNTED, just not escalated")
    }

    // MARK: - The web lane

    func testWebSubtreeIsChargedToTheWebBudgetNotTheNativeOne() {
        let root = node("AXWindow", [
            node("AXToolbar", [node("AXButton")]),
            node("AXWebArea", [node("AXLink"), node("AXLink"), node("AXLink")]),
        ])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(
            root,
            native: .init(maxDepth: 10, maxNodes: 10),
            web: .init(maxDepth: 10, maxNodes: 10),
            tallies: &tallies)

        // Native pays for window + toolbar + button only; the web area roots
        // the other lane and takes its own subtree with it.
        XCTAssertEqual(tallies.native.visited, 3)
        XCTAssertEqual(tallies.web.visited, 4)
        XCTAssertFalse(tallies.native.truncated)
        XCTAssertFalse(tallies.web.truncated)
    }

    /// The whole point of the escalation: a page that would have blown the
    /// window's budget is walked in full because the ceiling that applies to
    /// it is the page's, not the window chrome's.
    func testAPageTooBigForTheNativeBudgetSurvivesOnTheWebBudget() {
        let root = node("AXWindow", [node("AXWebArea", (1...50).map { _ in node("AXLink") })])
        var tallies = AXSnapshotBuilder.LaneTallies()
        let snapshot = build(
            root,
            native: .init(maxDepth: 10, maxNodes: 3),
            web: .init(maxDepth: 10, maxNodes: 100),
            tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 1, "only the window itself")
        XCTAssertEqual(tallies.web.visited, 51)
        XCTAssertFalse(tallies.web.truncated)
        XCTAssertEqual(snapshot.children.first?.children.count, 50)
    }

    func testWebDepthOriginResetsAtTheWebArea() {
        // The web area sits 3 native levels down; its own content is 2 deep.
        // A web depth budget of 2 must measure the PAGE's nesting, not the
        // page's distance from the window.
        let root = node("AXWindow", [
            node("AXGroup", [
                node("AXGroup", [
                    node("AXWebArea", [node("AXGroup", [node("AXLink")])]),
                ]),
            ]),
        ])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(
            root,
            native: .init(maxDepth: 10, maxNodes: 100),
            web: .init(maxDepth: 2, maxNodes: 100),
            tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 3)
        XCTAssertEqual(tallies.web.visited, 3, "web area + group + link, all within web depth 2")
        XCTAssertFalse(tallies.web.truncated)
    }

    func testWebDepthBudgetTruncatesInsideThePage() {
        let root = node("AXWindow", [
            node("AXWebArea", [node("AXGroup", [node("AXGroup", [node("AXLink")])])]),
        ])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(
            root,
            native: .init(maxDepth: 10, maxNodes: 100),
            web: .init(maxDepth: 2, maxNodes: 100),
            tallies: &tallies)

        XCTAssertEqual(tallies.web.visited, 3)
        XCTAssertTrue(tallies.web.truncated)
        XCTAssertFalse(tallies.native.truncated, "the native lane is untouched by a page's overflow")
    }

    func testTwoWebAreasShareOneWebBudget() {
        let root = node("AXWindow", [
            node("AXSplitGroup", [
                node("AXWebArea", (1...5).map { _ in node("AXLink") }),
                node("AXWebArea", (1...5).map { _ in node("AXLink") }),
            ]),
        ])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(
            root,
            native: .init(maxDepth: 10, maxNodes: 100),
            web: .init(maxDepth: 10, maxNodes: 8),
            tallies: &tallies)

        // One shared ceiling across both pages — bounded per window, the same
        // doctrine the native lane's shared counter follows.
        XCTAssertEqual(tallies.web.visited, 8)
        XCTAssertTrue(tallies.web.truncated)
        XCTAssertEqual(tallies.native.visited, 2)
        XCTAssertEqual(tallies.webAreaCount, 2)
    }

    /// An iframe is a web area inside a web area. It must NOT restart the
    /// budget — that would make a page with frames unbounded, which is the
    /// failure mode the shared tally exists to prevent.
    func testNestedWebAreaDoesNotReEscalate() {
        let root = node("AXWindow", [
            node("AXWebArea", [
                node("AXGroup", [node("AXWebArea", (1...5).map { _ in node("AXLink") })]),
            ]),
        ])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(
            root,
            native: .init(maxDepth: 10, maxNodes: 100),
            web: .init(maxDepth: 10, maxNodes: 4),
            tallies: &tallies)

        XCTAssertEqual(tallies.web.visited, 4, "the inner area keeps spending the same budget")
        XCTAssertTrue(tallies.web.truncated)
        XCTAssertEqual(tallies.native.visited, 1)
        XCTAssertEqual(tallies.webAreaCount, 2, "nested areas still count toward the total")
    }

    func testWebAreaCountIsZeroForAppsWithoutPages() {
        let root = node("AXWindow", [node("AXGroup", [node("AXButton")])])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .standard, web: .standard, tallies: &tallies)
        XCTAssertEqual(tallies.webAreaCount, 0)
    }

    // MARK: - The IPC diet

    func testUncategorisedNodesPayForNoSubroleOrLabel() {
        let reads = Reads()
        let root = node("AXUnknownFutureRole", [node("AXAnotherUnknown")])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .standard, reads: reads, tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 2)
        XCTAssertEqual(reads.subrole, 0, ".other nodes must not cost a subrole read")
        XCTAssertEqual(reads.label, 0, ".other nodes must not cost a label read")
        XCTAssertEqual(reads.frame, 2, "frame is always read — it is what gets drawn")
    }

    func testOnlyInteractiveNodesPayForEnabledAndFocused() {
        let reads = Reads()
        let root = node("AXWindow", [
            node("AXGroup"), node("AXStaticText"), node("AXImage"), node("AXButton"),
        ])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .standard, reads: reads, tallies: &tallies)

        XCTAssertEqual(reads.isEnabled, 1, "only the button")
        XCTAssertEqual(reads.isFocused, 1, "only the button")
        XCTAssertEqual(reads.subrole, 5, "every categorised node reads a subrole")
    }

    func testWebAreasAreCategorisedAndSoPayForTheirLabel() {
        // A page's title is exactly the label worth having on a wireframe;
        // before AXWebArea joined the table it fell to `.other` and the label
        // was never read.
        let reads = Reads()
        let root = node("AXWebArea")
        var tallies = AXSnapshotBuilder.LaneTallies()
        let snapshot = build(
            root, native: .standard, web: .standard, label: "Obsidian", reads: reads,
            tallies: &tallies)

        XCTAssertEqual(snapshot.category, .webArea)
        XCTAssertEqual(snapshot.label, "Obsidian")
        XCTAssertEqual(reads.label, 1)
    }

    // MARK: - Labels and identity

    func testLabelIsCappedWithAnEllipsis() {
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(AXSnapshotBuilder.capped(long, cap: 10), String(repeating: "a", count: 10) + "…")
        XCTAssertEqual(AXSnapshotBuilder.capped("short", cap: 10), "short")
        XCTAssertNil(AXSnapshotBuilder.capped("", cap: 10))
    }

    func testEveryVisitedNodeIsRecordedForTheElementTable() {
        let reads = Reads()
        let root = node("AXWindow", [node("AXWebArea", [node("AXLink")])])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .standard, web: .standard, reads: reads, tallies: &tallies)

        // The side table must cover both lanes — the streamer's frame-only
        // fast path looks up nodes by id without caring where they came from.
        XCTAssertEqual(reads.recorded.count, 3)
        XCTAssertEqual(Set(reads.recorded).count, 3)
    }
}

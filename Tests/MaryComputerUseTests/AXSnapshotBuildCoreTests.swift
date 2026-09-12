//
//  AXSnapshotBuildCoreTests.swift
//  MaryComputerUseTests
//
//  WHAT: Generic snapshot walk — parity with the BFS walker, IPC diet.
//  OUT:  AXSnapshotBuilder.buildNodeCore
//

import CoreGraphics
import XCTest
@testable import MaryComputerUse
import MaryComputerUseTestSupport

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

    func testNodeAtMaxDepthIsVisitedAndOnlyItsChildrenAreWithheld() {
        // A 4-node chain at depths 0..3, depth capped at 2.
        let root = node("AXWindow", [node("AXGroup", [node("AXGroup", [node("AXButton")])])])
        var tallies = AXSnapshotBuilder.LaneTallies()
        build(root, native: .init(maxDepth: 2, maxNodes: 100), tallies: &tallies)

        XCTAssertEqual(tallies.native.visited, 3, "the node AT maxDepth is still visited")
        XCTAssertTrue(tallies.native.truncated, "its withheld children are a truncation")
    }

    // MARK: - Cancellation

    private func cancellable(
        _ root: Node,
        native: AXTreeWalker.Budget = .init(maxDepth: 10, maxNodes: 1000),
        source: AXSnapshotBuilder.AXNodeSource<Node>,
        tallies: inout AXSnapshotBuilder.LaneTallies,
        isCancelled: @escaping () -> Bool
    ) -> AXNodeSnapshot {
        AXSnapshotBuilder.buildNodeCore(
            from: root,
            lane: .native,
            depth: 0,
            source: source,
            options: options(),
            budgets: .init(native: native, web: nil),
            tallies: &tallies,
            isCancelled: isCancelled)
    }

    /// THE REGRESSION GUARD. An uncancelled walk must be arithmetically
    /// identical to one with no hook at all — the whole change is invisible
    /// until somebody is actually cancelled.
    func testAnUncancelledWalkIsIdenticalToOneWithNoHook() {
        let shape = { self.node("AXWindow", [self.node("AXGroup", [self.node("AXButton")])]) }

        var withoutHook = AXSnapshotBuilder.LaneTallies()
        let plain = build(
            shape(), native: .init(maxDepth: 10, maxNodes: 1000), tallies: &withoutHook)

        var withHook = AXSnapshotBuilder.LaneTallies()
        let hooked = cancellable(
            shape(), source: source(), tallies: &withHook, isCancelled: { false })

        XCTAssertEqual(withHook.native.visited, withoutHook.native.visited)
        XCTAssertEqual(withHook.native.truncated, withoutHook.native.truncated)
        XCTAssertEqual(hooked.subtreeCount, plain.subtreeCount)
    }

    /// Cancelled before it starts: the node in hand is still described
    /// honestly, and nothing below it is touched.
    func testACancelledWalkKeepsTheNodeInHandAndStopsThere() {
        let root = node("AXWindow", (1...5).map { _ in self.node("AXButton") })
        var tallies = AXSnapshotBuilder.LaneTallies()
        let snapshot = cancellable(
            root, source: source(), tallies: &tallies, isCancelled: { true })

        XCTAssertEqual(tallies.native.visited, 1)
        XCTAssertTrue(tallies.native.truncated, "an incomplete tree is a truncated one")
        XCTAssertTrue(snapshot.children.isEmpty)
    }

    /// THE POINT OF STOPPING THERE. `children` is itself a round trip, so a
    /// cancelled walk must not ask for it — otherwise "stop" still costs one
    /// IPC call per node on the way out.
    func testACancelledWalkNeverAsksForChildren() {
        var childCalls = 0
        var counting = source()
        counting.children = { node in
            childCalls += 1
            return node.children
        }
        let root = node("AXWindow", (1...5).map { _ in self.node("AXButton") })
        var tallies = AXSnapshotBuilder.LaneTallies()
        _ = cancellable(
            root, source: counting, tallies: &tallies, isCancelled: { true })

        XCTAssertEqual(childCalls, 0, "a stopped walk pays for no further reads")
    }

    /// Cancelled partway: the siblings still queued are never visited, and the
    /// unwinding costs the depth rather than what was left.
    func testCancellationPartWayStopsTheRemainingSiblings() {
        var visits = 0
        var counting = source()
        counting.role = { node in
            visits += 1
            return node.role
        }
        let root = node("AXWindow", (1...20).map { _ in self.node("AXButton") })
        var tallies = AXSnapshotBuilder.LaneTallies()
        let snapshot = cancellable(
            root, source: counting, tallies: &tallies, isCancelled: { visits >= 4 })

        XCTAssertTrue(tallies.native.truncated)
        XCTAssertLessThan(
            snapshot.children.count, 20, "the queued siblings were abandoned")
        XCTAssertLessThan(visits, 20, "and never read")
    }

    // MARK: - The web lane

    /// The whole point of the escalation: a page that would have blown the
    /// window's budget is walked in full because the ceiling that applies to
    /// it is the page's, not the window chrome's.

    /// An iframe is a web area inside a web area. It must NOT restart the
    /// budget — that would make a page with frames unbounded, which is the
    /// failure mode the shared tally exists to prevent.

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

    // MARK: - Labels and identity

}

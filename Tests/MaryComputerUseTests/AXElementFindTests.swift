//
//  AXElementFindTests.swift
//  MaryComputerUseTests
//
//  WHAT: The finder's arithmetic, pinned without AX IPC.
//  PIN:  THE POINT OF THIS TYPE IS FEWER ROUND TRIPS, and a wall-clock test
//        cannot see one. MEASURED on Apple Music: the SAME 729-node walk took
//        4.1s and 52.6s on consecutive runs of the same binary, so timing
//        proves nothing here. These tests count VISITS instead — the thing
//        that actually determines the cost — over a synthetic tree.
//

import Testing
@testable import MaryComputerUse

@Suite struct AXElementFindTests {

    /// A synthetic node: children, and a name standing in for the one
    /// attribute a search reads before it decides.
    final class Node {
        let name: String
        let children: [Node]
        init(_ name: String, _ children: [Node] = []) {
            self.name = name
            self.children = children
        }
    }

    /// root
    ///  ├─ a ── a1, a2
    ///  ├─ b ── b1 ── b1x
    ///  └─ target
    static func tree() -> Node {
        Node("root", [
            Node("a", [Node("a1"), Node("a2")]),
            Node("b", [Node("b1", [Node("b1x")])]),
            Node("target"),
        ])
    }

    private func find(
        in root: Node,
        budget: AXTreeWalker.Budget = .standard,
        skipping: @escaping (Node) -> Bool = { _ in false },
        stopAt wanted: String?
    ) -> (found: Node?, visits: Int) {
        var visits = 0
        var found: Node?
        AXElementFind.walkCore(
            from: root,
            children: { $0.children },
            budget: budget,
            skipping: skipping,
            visit: { node, _ in
                visits += 1
                guard node.name == wanted else { return true }
                found = node
                return false
            })
        return (found, visits)
    }

    /// BREADTH-FIRST, which is the whole reason this is not `buildNodeCore`.
    /// A shallow node must be reached before a deep one — on the real tree the
    /// sidebar outline sits at depth 3 with several hundred rows beneath it.
    @Test func visitsBreadthFirst() {
        var order: [String] = []
        AXElementFind.walkCore(
            from: Self.tree(),
            children: { $0.children },
            budget: .standard,
            skipping: { _ in false },
            visit: { node, _ in order.append(node.name); return true })
        #expect(order == ["root", "a", "b", "target", "a1", "a2", "b1", "b1x"])
    }

    /// EARLY EXIT IS THE SAVING. Everything still queued when the predicate
    /// matches must never be read.
    @Test func stopsAtTheFirstMatch() {
        let all = find(in: Self.tree(), stopAt: nil).visits
        let hit = find(in: Self.tree(), stopAt: "target")
        #expect(hit.found?.name == "target")
        #expect(hit.visits == 4, "root, a, b, target — and nothing below them")
        #expect(hit.visits < all)
    }

    /// A skipped node is neither visited nor descended into — that is how
    /// `pressPagePlay` drops the library outline, which measured ~427 of
    /// Apple Music's ~729 nodes.
    @Test func skippingPrunesTheWholeSubtree() {
        let unpruned = find(in: Self.tree(), stopAt: nil).visits
        let pruned = find(
            in: Self.tree(), skipping: { $0.name == "a" }, stopAt: nil)
        #expect(unpruned == 8)
        #expect(
            pruned.visits == 5,
            "a is not visited, and a1/a2 are never queued — root, b, target, b1, b1x")
    }

    /// ...BUT IT STILL COUNTS AGAINST `maxNodes`. The skip saves round trips,
    /// not budget: a caller that skipped half a tree must not silently get a
    /// deeper walk of the other half than its budget allowed.
    @Test func aSkippedNodeStillSpendsItsNodeBudget() {
        let budget = AXTreeWalker.Budget(maxDepth: 24, maxNodes: 3)
        var visited: [String] = []
        AXElementFind.walkCore(
            from: Self.tree(), children: { $0.children }, budget: budget,
            skipping: { $0.name == "a" },
            visit: { node, _ in visited.append(node.name); return true })
        // root, a (skipped, counted), b — then the budget is spent.
        #expect(visited == ["root", "b"])
    }

    /// Node arithmetic matches `AXTreeWalker.walkCore`'s convention, so a
    /// search and a walk over the same tree agree on what `maxNodes` counted.
    @Test func nodeBudgetMatchesTheWalkerConvention() {
        let budget = AXTreeWalker.Budget(maxDepth: 24, maxNodes: 3)
        var searched: [String] = []
        AXElementFind.walkCore(
            from: Self.tree(), children: { $0.children }, budget: budget,
            skipping: { _ in false },
            visit: { node, _ in searched.append(node.name); return true })

        var walked: [String] = []
        AXTreeWalker.walkCore(
            from: Self.tree(), children: { $0.children }, budget: budget,
            visit: { node, _ in walked.append(node.name) })

        #expect(searched == walked)
    }

    /// A cancelled search stops at the next dequeue and reads nothing more —
    /// the same contract `AXSnapshotBuilder.buildNodeCore` honours, for the
    /// same reason: an abandoned search must stop making round trips against a
    /// target nobody is waiting on any more.
    @Test func aCancelledSearchStopsAndReadsNothingFurther() {
        var visits = 0
        AXElementFind.walkCore(
            from: Self.tree(),
            children: { $0.children },
            budget: .standard,
            skipping: { _ in false },
            isCancelled: { visits >= 2 },
            visit: { _, _ in visits += 1; return true })
        #expect(visits == 2, "stopped at the next dequeue, not at the end of the tree")
    }

    /// And with no cancellation the arithmetic is untouched.
    @Test func anUncancelledSearchIsUnchanged() {
        var visited: [String] = []
        AXElementFind.walkCore(
            from: Self.tree(), children: { $0.children }, budget: .standard,
            skipping: { _ in false }, isCancelled: { false },
            visit: { node, _ in visited.append(node.name); return true })
        #expect(visited.count == 8)
    }

    /// Depth stops descent, not the visit itself.
    @Test func depthBudgetStopsDescentNotTheVisit() {
        let budget = AXTreeWalker.Budget(maxDepth: 1, maxNodes: 100)
        var order: [String] = []
        AXElementFind.walkCore(
            from: Self.tree(), children: { $0.children }, budget: budget,
            skipping: { _ in false },
            visit: { node, _ in order.append(node.name); return true })
        #expect(order == ["root", "a", "b", "target"])
    }
}

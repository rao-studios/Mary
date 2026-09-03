//
//  AXTreeWalkerTests.swift
//  MaryComputerUseTests
//
//  WHAT: Shared BFS walker budget arithmetic on synthetic graphs.
//  OUT:  AXTreeWalker.walkCore
//

import XCTest
@testable import MaryComputerUse
import MaryComputerUseTestSupport

final class AXTreeWalkerTests: XCTestCase {

    private struct Node {
        let id: Int
        let children: [Node]
    }

    private func tree(_ id: Int, _ children: [Node] = []) -> Node {
        Node(id: id, children: children)
    }

    // MARK: - BFS order

    func testVisitsBreadthFirst() {
        // 1 → [2, 3]; 2 → [4]; 3 → [5]
        let root = tree(1, [tree(2, [tree(4)]), tree(3, [tree(5)])])
        var order: [Int] = []
        AXTreeWalker.walkCore(
            from: root, children: { $0.children },
            budget: .init(maxDepth: 10, maxNodes: 10)
        ) { node, _ in order.append(node.id) }
        XCTAssertEqual(order, [1, 2, 3, 4, 5])
    }

    // MARK: - Node cap: the legacy off-by-one, preserved exactly

    func testNodeCapVisitsExactlyMaxNodesAndAbortsBeforeTheNext() {
        // A flat root with 5 children — 6 nodes total (root + 5).
        let root = tree(0, (1...5).map { tree($0) })
        var visited: [Int] = []
        AXTreeWalker.walkCore(
            from: root, children: { $0.children },
            budget: .init(maxDepth: 10, maxNodes: 3)
        ) { node, _ in visited.append(node.id) }
        // Exactly 3 nodes visited (root, child 1, child 2) — the 4th dequeue
        // increments `visited` past the cap and returns BEFORE calling visit.
        XCTAssertEqual(visited, [0, 1, 2])
    }

    // MARK: - Depth cap: a node AT maxDepth is visited, its children are not

    func testDepthCapVisitsTheLimitNodeButNotItsChildren() {
        // 0 → 1 → 2 → 3 (a 4-node chain, depths 0..3)
        let root = tree(0, [tree(1, [tree(2, [tree(3)])])])
        var visited: [Int] = []
        AXTreeWalker.walkCore(
            from: root, children: { $0.children },
            budget: .init(maxDepth: 2, maxNodes: 100)
        ) { node, _ in visited.append(node.id) }
        // Depth 2 (id 2) is visited — `guard depth < maxDepth` only WITHHOLDS
        // children, it does not skip the node's own visit.
        XCTAssertEqual(visited, [0, 1, 2])
    }

    // MARK: - A single leaf root

}

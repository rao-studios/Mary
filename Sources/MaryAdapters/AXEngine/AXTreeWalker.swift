//
//  AXTreeWalker.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  Mary grew five bounded breadth-first walkers over the accessibility
//  tree, independently, in `SafariWebSurface`, `ProbeShaderFeel`, and (left
//  alone this pass — see AXEngine.swift) `AXSelectionReader`/`PagesAX`'s
//  `descendToText` and `RemoteHandsStateProvider`'s children descent. Two of
//  those five — SafariWebSurface's and ProbeShaderFeel's — were the SAME
//  loop, verbatim, at two different budgets. This file is that loop, once,
//  with the budget as a value instead of a pair of file-private constants.
//
//  The generic `walkCore` exists so the exact BFS/budget arithmetic can be
//  pinned by a test without AX IPC: synthetic node graphs stand in for
//  `AXUIElement`/`AX.children`.
//

import ApplicationServices

public enum AXTreeWalker {

    /// A walk's depth/node ceiling. Bounded on purpose — a loaded web page or
    /// a large native window is a big tree, and an unbounded walk is a stall
    /// waiting to happen.
    public struct Budget: Sendable, Equatable {
        public var maxDepth: Int
        public var maxNodes: Int

        public init(maxDepth: Int, maxNodes: Int) {
            self.maxDepth = maxDepth
            self.maxNodes = maxNodes
        }

        /// The budget SafariWebSurface and ProbeShaderFeel both shipped with.
        public static let standard = Budget(maxDepth: 24, maxNodes: 4000)
    }

    /// Bounded breadth-first walk of a live accessibility tree.
    ///
    /// Preserves the exact legacy arithmetic byte-for-bit: the node is
    /// counted as visited BEFORE the cap check (so exactly `maxNodes` nodes
    /// are ever visited, and the (maxNodes+1)th dequeue aborts before being
    /// visited), and a node AT `maxDepth` is still visited — only its
    /// children are withheld.
    public static func walk(
        from root: AXUIElement,
        budget: Budget = .standard,
        visit: (AXUIElement, Int) -> Void
    ) {
        walkCore(
            from: root,
            children: { AX.children($0) },
            budget: budget,
            visit: visit)
    }

    /// The generic core, over any node type with a `children` accessor.
    /// `walk(from:budget:visit:)` above is `walkCore` specialized to
    /// `AXUIElement` via `AX.children`; a test specializes it to a plain
    /// struct graph so the BFS/budget behavior is pinned without live AX.
    static func walkCore<Node>(
        from root: Node,
        children: (Node) -> [Node],
        budget: Budget,
        visit: (Node, Int) -> Void
    ) {
        var queue: [(node: Node, depth: Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if visited > budget.maxNodes { return }
            visit(node, depth)
            guard depth < budget.maxDepth else { continue }
            for child in children(node) { queue.append((child, depth + 1)) }
        }
    }
}

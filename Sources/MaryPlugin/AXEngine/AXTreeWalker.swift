//
//  AXTreeWalker.swift
//  MaryAdapter
//
//  WHAT: Bounded BFS of an accessibility tree. Budget is a value.
//  OUT:  AXSnapshotBuilder | WebAreaLocator
//  PIN:  walkCore is generic so tests pin arithmetic without AX IPC.

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

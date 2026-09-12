//
//  AXElementFind.swift
//  MaryComputerUse
//
//  WHAT: Find live elements by predicate. Bounded BFS, early exit, lazy reads.
//  IN:   AXTreeWalker.Budget
//  OUT:  AXUIElement handles — live, never an AXNodeID that can go stale
//  PIN:  A SEARCH IS NOT A SNAPSHOT, and building one to answer a search is
//        most of what made the media lane slow. `AXSnapshotBuilder.build`
//        describes every node it meets — role, subrole, label, frame (two
//        reads), enabled, focused, children — because a snapshot's consumer
//        may ask for any of it. A search asks one question: role, and a label
//        only where the role already matched. MEASURED on Apple Music: 729
//        nodes, ~7ms each, ~5.1s for a whole-app walk — paid twice by
//        `play_playlist` to reach an outline that is the FOURTH node visited.
//  PIN:  BREADTH-FIRST, and that is the point. The things worth finding — a
//        sidebar outline, a page's Play button — sit shallow; the lists they
//        contain sit deep. BFS pays only for nodes at depth ≤ the target's.
//        `AXSnapshotBuilder.buildNodeCore` is depth-first pre-order and its
//        arithmetic is pinned by tests, so this is a sibling, not a flag on it.
//

import ApplicationServices
import CoreGraphics

public enum AXElementFind {

    /// One visited node, read lazily.
    ///
    /// `role` is eager — every predicate needs it, so there is nothing to
    /// defer. `label` and `frame` are not: a predicate should test `role`
    /// first and let the cheap miss end the comparison, which is what keeps
    /// the overwhelming majority of nodes at two round trips (role +
    /// children) instead of the snapshot builder's five to nine.
    public struct Candidate {
        public let element: AXUIElement
        public let depth: Int
        public let role: String?

        private let slot: LazySlot

        init(element: AXUIElement, depth: Int, role: String?) {
            self.element = element
            self.depth = depth
            self.role = role
            self.slot = LazySlot()
        }

        /// The title→description ladder, IDENTICAL to
        /// `AXSnapshotBuilder.AXNodeSource.live.rawLabel` — a search that
        /// matched a different ladder than the snapshot would find a
        /// different element, which is the one way this can be wrong.
        public var label: String? { slot.label(of: element) }

        public var frame: CGRect? { slot.frame(of: element) }
    }

    /// Per-node memo so a predicate reading `label` twice pays one round trip.
    /// A class, because `Candidate` is a value handed to a non-escaping
    /// closure and the memo must outlive the read.
    final class LazySlot {
        private var labelResolved = false
        private var labelValue: String?
        private var frameResolved = false
        private var frameValue: CGRect?

        func label(of element: AXUIElement) -> String? {
            if labelResolved { return labelValue }
            labelResolved = true
            labelValue = AX.string(element, kAXTitleAttribute)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? AX.string(element, kAXDescriptionAttribute)
                    .flatMap { $0.isEmpty ? nil : $0 }
            return labelValue
        }

        func frame(of element: AXUIElement) -> CGRect? {
            if frameResolved { return frameValue }
            frameResolved = true
            frameValue = AX.frame(of: element)
            return frameValue
        }
    }

    /// The first element under `root` the predicate accepts, or nil.
    ///
    /// Stops the instant it matches — queued elements are never read, which is
    /// the whole saving over a snapshot.
    public static func first(
        under root: AXUIElement,
        budget: AXTreeWalker.Budget = .standard,
        skipping: [AXUIElement] = [],
        isCancelled: () -> Bool = { Task.isCancelled },
        where matches: (Candidate) -> Bool
    ) -> AXUIElement? {
        var found: AXUIElement?
        walk(under: root, budget: budget, skipping: skipping, isCancelled: isCancelled) { candidate in
            guard matches(candidate) else { return true }
            found = candidate.element
            return false
        }
        return found
    }

    /// Every element under `root` the predicate accepts.
    ///
    /// For a rule that needs all candidates before it can choose — "the
    /// largest Play button outside the transport" cannot early-exit, but it
    /// can still skip the subtrees it does not care about.
    public static func all(
        under root: AXUIElement,
        budget: AXTreeWalker.Budget = .standard,
        skipping: [AXUIElement] = [],
        isCancelled: () -> Bool = { Task.isCancelled },
        where matches: (Candidate) -> Bool
    ) -> [AXUIElement] {
        var found: [AXUIElement] = []
        walk(under: root, budget: budget, skipping: skipping, isCancelled: isCancelled) { candidate in
            if matches(candidate) { found.append(candidate.element) }
            return true
        }
        return found
    }

    /// The live walk. `visit` returns false to stop.
    ///
    /// A SEARCH IS ABANDONED THE SAME WAY A WALK IS. `bounded()` cancels the
    /// loser of a race and stops waiting on it; without this the search kept
    /// making round trips against the target's AX server with nobody left to
    /// receive the answer. Same default and same reasoning as
    /// `AXSnapshotBuilder.build`.
    private static func walk(
        under root: AXUIElement,
        budget: AXTreeWalker.Budget,
        skipping: [AXUIElement],
        isCancelled: () -> Bool = { Task.isCancelled },
        visit: (Candidate) -> Bool
    ) {
        walkCore(
            from: root,
            children: { AX.children($0) },
            budget: budget,
            skipping: { element in skipping.contains { CFEqual($0, element) } },
            isCancelled: isCancelled,
            visit: { element, depth in
                visit(Candidate(
                    element: element,
                    depth: depth,
                    role: AX.string(element, kAXRoleAttribute)))
            })
    }

    /// The generic core, over any node type — the `AXTreeWalker.walkCore`
    /// doctrine with the two things a search needs that a walk does not: a
    /// stop, and a subtree skip.
    ///
    /// Node arithmetic matches `walkCore`'s convention exactly: `visited` is
    /// incremented on dequeue and the budget is checked before the visit, so a
    /// search and a walk over the same tree agree on what "maxNodes" counted.
    /// A skipped node is dequeued and counted; its children are never queued.
    static func walkCore<Node>(
        from root: Node,
        children: (Node) -> [Node],
        budget: AXTreeWalker.Budget,
        skipping: (Node) -> Bool,
        isCancelled: () -> Bool = { false },
        visit: (Node, Int) -> Bool
    ) {
        var queue: [(node: Node, depth: Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if visited > budget.maxNodes { return }
            // Asked once per dequeue, before any read this node would cause.
            if isCancelled() { return }
            if skipping(node) { continue }
            guard visit(node, depth) else { return }
            guard depth < budget.maxDepth else { continue }
            for child in children(node) { queue.append((child, depth + 1)) }
        }
    }
}

//
//  WebAreaLocator.swift
//  MaryComputerUse
//
//  WHAT: Find AXWebArea roots. Nothing else.
//  IN:   AXTreeWalker.Budget.standard  OUT: WebContentHost / AXSnapshotBuilder
//  PIN:  Page semantics stay in PageElementReader. AXEngine must not import Shared/.

import ApplicationServices

enum WebAreaLocator {

    static let webAreaRole = "AXWebArea"

    /// The wake lane's probe: does this application currently expose a page?
    static func firstWebArea(inApp application: AXUIElement) -> AXUIElement? {
        guard let window = AX.element(application, kAXFocusedWindowAttribute)
                ?? AX.element(application, kAXMainWindowAttribute)
        else { return nil }
        return webAreas(inWindow: window, budget: .standard, limit: 1).first
    }

    /// Every web area under one window, in breadth-first order.
    static func webAreas(
        inWindow window: AXUIElement,
        budget: AXTreeWalker.Budget = .standard,
        limit: Int = .max
    ) -> [AXUIElement] {
        webAreasCore(
            from: window,
            children: { AX.children($0) },
            role: { AX.string($0, kAXRoleAttribute) },
            budget: budget,
            limit: limit)
    }

    /// The generic core, over any node type — the `AXTreeWalker.walkCore` doctrine applied
    /// one level up, so the.
    static func webAreasCore<Node>(
        from root: Node,
        children: (Node) -> [Node],
        role: (Node) -> String?,
        budget: AXTreeWalker.Budget,
        limit: Int = .max
    ) -> [Node] {
        var found: [Node] = []
        AXTreeWalker.walkCore(from: root, children: children, budget: budget) { node, _ in
            guard found.count < limit, role(node) == webAreaRole else { return }
            found.append(node)
        }
        return found
    }
}

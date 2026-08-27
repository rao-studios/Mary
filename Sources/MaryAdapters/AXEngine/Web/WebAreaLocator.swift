//
//  WebAreaLocator.swift
//  MaryAdapter
//
//  THE AX ENGINE / WEB SUB-ENGINE — see AXEngine.swift for the directory's
//  doctrine header.
//
//  FINDS `AXWebArea` ROOTS, and nothing else. Small on purpose: the wake lane
//  needs one honest "is there a page here yet?" verdict, and the wireframe
//  wants "how many pages does this window hold" for its HUD. Neither is a
//  page-SEMANTIC question — reading order, element kinds, dedup and the
//  label ladder all stay in `Shared/PageElementReader.swift`, which starts
//  where this file stops.
//
//  WHY THIS EXISTS RATHER THAN A CALL INTO THE SAFARI LANE. `BrowserAXReadiness`
//  used to answer "is the page up?" by calling `SafariWebSurface.webArea` —
//  an AXEngine file reaching outward into `Shared/`'s browser adapter, which
//  is backwards for what is supposed to be the layer underneath. The probe
//  is a bounded BFS for one role; owning it here severs that edge and costs
//  a dozen lines. The Safari lane keeps its own copy untouched (it carries
//  the `.first`/`.largest` strategy split that its callers depend on, and
//  re-pointing those is a separate pass with its own live verification).
//
//  BUDGET PARITY IS DELIBERATE: `AXTreeWalker.Budget.standard` (24/4000) is
//  exactly `SafariWebSurface.maxSearchDepth`/`maxSearchNodes`, so the
//  readiness verdicts this file now produces are bit-identical to the ones
//  the Safari-lane probe produced before the switch.
//

import ApplicationServices

enum WebAreaLocator {

    static let webAreaRole = "AXWebArea"

    /// The wake lane's probe: does this application currently expose a page?
    /// Reads the focused-or-main window the same way the Safari lane does
    /// (focus first, main as the fallback for an app whose window is up but
    /// not key) and answers with the first web area breadth-first.
    static func firstWebArea(inApp application: AXUIElement) -> AXUIElement? {
        guard let window = AX.element(application, kAXFocusedWindowAttribute)
                ?? AX.element(application, kAXMainWindowAttribute)
        else { return nil }
        return webAreas(inWindow: window, budget: .standard, limit: 1).first
    }

    /// Every web area under one window, in breadth-first order. A page with
    /// nested iframes exposes several; the wireframe wants the count, and a
    /// `limit` of 1 turns this into the probe above without a second walk
    /// shape to keep honest.
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

    /// The generic core, over any node type — the `AXTreeWalker.walkCore`
    /// doctrine applied one level up, so the discovery/limit behavior is
    /// pinned by a test on synthetic graphs without live AX (see
    /// WebAreaLocatorTests).
    ///
    /// Note it cannot early-RETURN out of `walkCore` (that walk has no stop
    /// signal), so `limit` gates collection rather than traversal: the walk
    /// still costs its budget, the array stops growing. For the probe's
    /// `limit: 1` that is the same IPC the old Safari-lane probe spent,
    /// which is the point.
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

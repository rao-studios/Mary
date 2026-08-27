//
//  AXHitTest.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  "WHICH ELEMENT IS AT THIS POINT" — the geometric complement to
//  `AXDesktopPlane`'s coordinate flip. A published `AXAppSnapshot` already
//  carries every node's frame; this file answers the one question that
//  frame data exists to answer besides drawing: given an AX-space point,
//  what is the SMALLEST thing there. That is a general property of the
//  snapshot, not a Clyde-specific one (Clyde's click-to-zoom is this file's
//  first consumer, not its only imaginable one — the same doctrine that put
//  `AXDesktopPlane` here rather than in `ClydeApp`), so it lives beside the
//  other pure geometry.
//
//  SMALLEST AREA, NOT LAST DRAWN. `WireframeRenderer` draws parents before
//  children, so "last drawn" and "most specific" usually coincide — but a
//  child's reported frame can, in real AX data, extend beyond its parent's
//  (a misreporting app, an overflowing element). Ranking every candidate
//  by area rather than by recursion order is what keeps a click resolving
//  to the intuitively smallest/most-specific thing even when frames don't
//  nest perfectly.
//
//  A WINDOW IS A VALID TARGET TOO. Windows and nodes are ranked in the same
//  pass: a window's frame almost always contains its whole content tree, so
//  it only wins when no content element sits under the point at all —
//  clicking a window's empty background zooms to "this window," clicking
//  anything drawn inside it zooms to that instead. No special-casing needed.
//
//  THE SIZE FLOOR exists because of a measured, real shape: an
//  `aria-live`-announcer element (screen-reader-only, positioned off-visual
//  or collapsed) reports a real frame — 1×1 points, seen live in GitHub
//  Desktop's tree (`AXStaticText value="fetch complete" (744,121 85x1)`).
//  Without a floor, one of these can win a hit test and zoom the whole
//  stage into a hairline with nothing visible in it.
//

import CoreGraphics

public enum AXHitTest {

    /// What a hit test resolves to: enough to zoom a stage into it and to
    /// label a breadcrumb crumb for it.
    public struct Target: Sendable, Equatable {
        public let id: AXNodeID
        public let frame: CGRect
        public let label: String
        public let isWindow: Bool
    }

    /// Below this on either axis, a frame is not a usable zoom target — see
    /// the header's aria-live-announcer note.
    public static let minimumExtent: CGFloat = 2

    /// The smallest window-or-node frame containing `point`, or `nil` when
    /// nothing does (empty desktop background, or a window's dead margin
    /// outside every screen-reported element).
    public static func target(in snapshot: AXAppSnapshot, at point: CGPoint) -> Target? {
        var best: Target?
        var bestArea = CGFloat.greatestFiniteMagnitude

        func consider(_ candidate: Target) {
            guard usable(candidate.frame), candidate.frame.contains(point) else { return }
            let area = candidate.frame.width * candidate.frame.height
            // A content node that exactly fills its window (a single
            // full-bleed pane, no inset) ties the window on area — and must
            // still win, because it is the more specific thing under the
            // point. Content is walked after its window below, so a bare
            // `<` would let the window's earlier, equal-area entry stand.
            let winsTie = area == bestArea && best?.isWindow == true && !candidate.isWindow
            guard area < bestArea || winsTie else { return }
            bestArea = area
            best = candidate
        }

        for window in snapshot.windows {
            if let frame = window.frame {
                consider(Target(
                    id: window.id, frame: frame,
                    label: window.title.isEmpty ? "Window" : window.title,
                    isWindow: true))
            }
            if let root = window.root {
                root.forEachNode { node in
                    guard let frame = node.frame else { return }
                    consider(Target(
                        id: node.id, frame: frame,
                        label: node.label ?? node.role,
                        isWindow: false))
                }
            }
        }
        return best
    }

    /// Re-locates one previously-resolved id's CURRENT frame in a fresher
    /// snapshot — how a live zoom stays put (or tracks a moving window)
    /// across publishes instead of freezing on a stale rect. `nil` when the
    /// id is no longer present (the element or window is gone); the caller
    /// decides what "gone" means for its own navigation state.
    public static func frame(of id: AXNodeID, in snapshot: AXAppSnapshot) -> CGRect? {
        for window in snapshot.windows {
            if window.id == id { return window.frame }
            if let root = window.root, let found = frame(of: id, in: root) {
                return found
            }
        }
        return nil
    }

    private static func frame(of id: AXNodeID, in node: AXNodeSnapshot) -> CGRect? {
        if node.id == id { return node.frame }
        for child in node.children {
            if let found = frame(of: id, in: child) { return found }
        }
        return nil
    }

    /// HOW MANY LEVELS OF A ZOOM TRAIL SURVIVE navigating to `target` —
    /// oldest first, most-recently-zoomed last; the caller appends `target`
    /// itself after keeping this many entries.
    ///
    /// THE BUG THIS FIXES: `target(in:at:)` searches the whole snapshot, not
    /// just the currently-focused subtree, so a tap while zoomed in can
    /// resolve to something OUTSIDE the current focus — an outer container
    /// (an ancestor, or a window) that the current focus sits inside. Always
    /// appending treats that as drilling deeper, which is backwards: the
    /// breadcrumb grows with an entry that's actually a level higher, and
    /// alternating taps between two already-visited levels never matches
    /// `zoomStack.last?.id` (each is unequal to the immediately preceding
    /// one), so the trail grows without bound.
    ///
    /// The fix reads directly off geometry, with no tree-parent tracking
    /// needed: an outer container's frame CONTAINS what's inside it, so any
    /// trailing level `target` itself contains was made obsolete by this
    /// navigation — drop it, don't stack a shallower level under a deeper
    /// one. A target that does NOT contain the current focus (the ordinary
    /// case — a genuine descendant, or an unrelated node elsewhere) pops
    /// nothing, so the caller's plain append is unaffected.
    public static func trailDepth(_ trail: [CGRect], navigatingTo target: CGRect) -> Int {
        var depth = trail.count
        while depth > 0, target.contains(trail[depth - 1]) {
            depth -= 1
        }
        return depth
    }

    private static func usable(_ frame: CGRect) -> Bool {
        frame.width >= minimumExtent && frame.height >= minimumExtent
    }
}

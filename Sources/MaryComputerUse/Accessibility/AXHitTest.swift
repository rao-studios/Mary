//
//  AXHitTest.swift
//  MaryComputerUse
//
//  WHAT: Smallest published thing at an AX-space point.
//  IN:   AXAppSnapshot frames  OUT: window | node
//  PIN:  Smallest area, not last-drawn. Size floor skips 1-pt announcer frames.

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
            // A content node that exactly fills its window (a single full-bleed pane, no
            // inset) ties the window on area — and must still win, because it is the more
            // specific thing under the point.
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

    /// Re-locates one previously-resolved id's CURRENT frame in a fresher snapshot — how a
    /// live zoom stays put (or tracks a moving window) across publishes instead.
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

    /// HOW MANY LEVELS OF A ZOOM TRAIL SURVIVE navigating to `target` — oldest first,
    /// most-recently-zoomed last; the caller appends `target` itself after keeping this
    /// many entries.
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

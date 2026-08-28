//
//  WebProbeWindows.swift
//  WebProbe
//
//  WHICH WINDOW HOLDS THE PAGE, and does the lane look in it?
//
//  This exists because the first live run of `wake` disagreed with itself:
//  the probe's own walk found a web area while `BrowserAXReadiness` — the
//  shipped door, on the same process in the same second — reported
//  `axTreeAbsent` after its full six-second budget. Exactly one of the two
//  differences between those walks can explain it, and guessing which would
//  put the fix in the wrong file:
//
//    • the probe reads EVERY window; the lane reads focused-or-main only
//    • the probe recurses without a node budget; the lane spends
//      `AXTreeWalker.Budget.standard` (depth 24 / 4000 nodes) breadth-first
//
//  So this subcommand prints, per window: its title, whether it is the
//  focused or main one, the DEPTH at which a web area first appears, and how
//  many nodes a breadth-first walk visits before reaching it. A web area at
//  depth 7 that costs 5,000 nodes to reach is a budget bug; a web area in a
//  window that is neither focused nor main is a window-selection bug. They
//  are different repairs.
//
//  MEASURED 2026-08-28, macOS 26 — and the answer was neither:
//
//    • Chrome 151 publishes a web area at DEPTH 8, reached in 60 nodes. Well
//      inside the budget. But one of its two windows — visible, not
//      minimized, merely on a second display — published 74 nodes of native
//      chrome and NO WEB AREA AT ALL, repeatedly, and did not acquire one
//      after a full six-second wake. So `.axTreeAbsent` is not a transient
//      state a longer timeout would fix: it is reachable on a live, visible
//      window, and the three-case verdict is what keeps the lane from calling
//      it an empty page.
//    • Safari publishes at DEPTH 6, reached in 30 nodes — but NOT four
//      seconds after `open`. The first read of a freshly launched Safari
//      found no web area; the same read moments later found one. Nothing was
//      wrong; the page had not finished. That is the whole argument for a
//      settle check standing between navigation and reading, and it is why
//      `WebLoadSettle`'s absence would show up as intermittent blindness
//      rather than as an error.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin

enum WebProbeWindows {

    static let webAreaRole = "AXWebArea"

    static func run(_ application: NSRunningApplication) async {
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier
        let name = application.localizedName ?? "\(pid)"

        print("▸ \(name) (pid \(pid), \(bundleID ?? "no bundle id"))")

        let element = AXUIElementCreateApplication(pid)
        let focused = AX.element(element, kAXFocusedWindowAttribute)
        let main = AX.element(element, kAXMainWindowAttribute)
        let windows = AX.children(element, kAXWindowsAttribute)

        print("""
          focused     \(focused.map { AX.string($0, kAXTitleAttribute) ?? "(untitled)" } ?? "NONE")
          main        \(main.map { AX.string($0, kAXTitleAttribute) ?? "(untitled)" } ?? "NONE")
          windows     \(windows.count)
        """)

        guard !windows.isEmpty else {
            print("\n  No windows at all — nothing to search.")
            return
        }

        for (index, window) in windows.enumerated() {
            let title = AX.string(window, kAXTitleAttribute) ?? "(untitled)"
            let role = AX.string(window, kAXRoleAttribute) ?? "—"
            let subrole = AX.string(window, kAXSubroleAttribute)
            var marks: [String] = []
            if let focused, CFEqual(focused, window) { marks.append("FOCUSED") }
            if let main, CFEqual(main, window) { marks.append("MAIN") }

            let found = breadthFirstWebArea(in: window)

            // WHY A WINDOW MIGHT PUBLISH NO PAGE. Chromium throttles work for
            // windows nobody is looking at, so "minimized" and "off on another
            // Space" are candidate explanations for an absent web area — and
            // they are the difference between a lane bug and a lane that must
            // RAISE a window before it can read the page in it.
            let minimized = AX.number(window, kAXMinimizedAttribute)?.boolValue ?? false
            let frame = AX.frame(of: window)
            let onScreen = frame.map { rect in
                NSScreen.screens.contains { $0.frame.intersects(rect) }
            } ?? false

            print("""

              [\(index)] \(role)\(subrole.map { "/\($0)" } ?? "") \"\(title)\"\
            \(marks.isEmpty ? "" : "  ← \(marks.joined(separator: " + "))")
                  web area   \(found.depth.map { "depth \($0)" } ?? "NOT FOUND")\
             · \(found.visited) nodes visited\(found.exhausted ? " (BUDGET EXHAUSTED)" : "")
                  window     \(minimized ? "MINIMIZED" : "not minimized") · \
            \(onScreen ? "on a screen" : "OFF-SCREEN (another Space, or positioned away)") · \
            \(frame.map { String(format: "%.0f,%.0f %.0f×%.0f", $0.origin.x, $0.origin.y, $0.width, $0.height) } ?? "no frame")
            """)
        }

        print("""

          Reading this: the lane searches only the window marked FOCUSED (or
          MAIN when nothing is focused), breadth-first, and stops at depth 24
          or 4,000 nodes. A page found here but not there is one of those two
          limits, and the line above says which.
        """)
    }

    /// The lane's own walk shape — breadth-first, depth 24, 4,000 nodes —
    /// instrumented to report where it got to. Deliberately a separate
    /// implementation from `WebAreaLocator`: this one must be able to report
    /// EXHAUSTION, which the lane's version has no reason to expose.
    static func breadthFirstWebArea(
        in window: AXUIElement,
        maxDepth: Int = 24,
        maxNodes: Int = 4000
    ) -> (depth: Int?, visited: Int, exhausted: Bool) {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0

        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if visited > maxNodes { return (nil, visited - 1, true) }

            if AX.string(element, kAXRoleAttribute) == webAreaRole {
                return (depth, visited, false)
            }
            guard depth < maxDepth else { continue }
            for child in AX.children(element, kAXChildrenAttribute) {
                queue.append((child, depth + 1))
            }
        }
        return (nil, visited, false)
    }
}

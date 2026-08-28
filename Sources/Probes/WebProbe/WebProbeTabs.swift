//
//  WebProbeTabs.swift
//  WebProbe
//
//  THE TAB STRIP, AS ACCESSIBILITY DESCRIBES IT — the measurement the browser
//  surface lane's design waits on.
//
//  The predecessor read tabs over AppleScript, because each browser vends a
//  scripting dictionary with a `tabs` collection and that was the road it
//  took. Mary sends no Apple Events, so the question has to be asked again
//  from the other side: does a browser's own AX tree name its tabs, and can
//  one be pressed? Apple Music's playlists turned out to be an ordinary
//  AXOutline for exactly this reason — the earlier answer described the road,
//  not the destination.
//
//  What this prints, per container that could be a tab strip:
//    • the container's role, subrole and title
//    • each child's role, title, AXValue, selected state, and frame
//    • whether AXPress is in the child's ADVERTISED action list
//
//  That last column is the one the design turns on. A tab that advertises
//  AXPress can be activated by identity, which is precise and survives the
//  strip re-flowing. A tab that does not forces the ordinal-chord fallback
//  (⌘1…⌘9), which is a POSITION and therefore wrong the moment a tab moves —
//  so which browsers need it is a fact worth having before, not after.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin

enum WebProbeTabs {

    /// Roles that plausibly hold a set of tabs. Deliberately WIDER than the
    /// expected `AXTabGroup`: the point of a measurement is to find out, and
    /// a probe that only looks where it expects confirms its own assumption.
    static let containerRoles: Set<String> = [
        "AXTabGroup", "AXToolbar", "AXRadioGroup", "AXGroup", "AXList",
    ]

    static func run(_ application: NSRunningApplication) async {
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier
        let name = application.localizedName ?? "\(pid)"
        let kind = WebContentHost.classify(pid: pid, bundleID: bundleID)

        print("▸ \(name) (pid \(pid), \(bundleID ?? "no bundle id")) · host \(kind.rawValue)")

        // Wake first. A Chromium tab strip is native chrome and is usually up
        // regardless, but waking costs nothing here and removes one variable
        // from a surprising result.
        let readiness = await BrowserAXReadiness.ensureWebContentAX(
            pid: pid, bundleID: bundleID)
        print("  readiness   \(readiness)")

        let element = AXUIElementCreateApplication(pid)
        guard let window = AX.element(element, kAXFocusedWindowAttribute)
                ?? AX.element(element, kAXMainWindowAttribute) else {
            print("  No focused or main window — nothing to read.")
            return
        }
        print("  window      \(AX.string(window, kAXTitleAttribute) ?? "—")")

        var candidates: [(element: AXUIElement, depth: Int)] = []
        collect(window, depth: 0, into: &candidates)

        guard !candidates.isEmpty else {
            print("""

              No container of any candidate role holds ≥2 titled children.
              Either this window has one tab, or this browser does not publish
              its strip — which is the finding, and the roster would then have
              to ride chords alone.
            """)
            return
        }

        for (container, depth) in candidates {
            let role = AX.string(container, kAXRoleAttribute) ?? "—"
            let subrole = AX.string(container, kAXSubroleAttribute)
            let title = AX.string(container, kAXTitleAttribute)
            let children = AX.children(container, kAXChildrenAttribute)

            print("""

              ┌ \(role)\(subrole.map { " / \($0)" } ?? "")\(title.map { " \"\($0)\"" } ?? "") \
            · depth \(depth) · \(children.count) children
            """)

            for (index, child) in children.enumerated() {
                let childRole = AX.string(child, kAXRoleAttribute) ?? "—"
                let childTitle = AX.string(child, kAXTitleAttribute)
                let childValue = AX.string(child, kAXValueAttribute)
                let selected = AX.number(child, kAXSelectedAttribute)?.boolValue
                let actions = actionNames(child)
                let frame = AX.frame(of: child)

                let label = childTitle ?? childValue ?? "—"
                let selectedMark = selected == true ? " ●selected" : ""
                let press = actions.contains(kAXPressAction as String) ? "AXPress" : "no AXPress"
                let geometry = frame.map {
                    String(format: "%.0f×%.0f", $0.width, $0.height)
                } ?? "no frame"

                print("""
                  │ \(index + 1). \(childRole)  \"\(label)\"\(selectedMark)
                  │    \(press) · \(geometry) · actions: \(actions.isEmpty ? "none" : actions.joined(separator: ", "))
                """)
                if childTitle == nil, childValue != nil {
                    print("  │    ⚠︎ title is EMPTY — the name is in AXValue, so a"
                        + " roster reading titles alone would see nothing")
                }
            }
        }

        print("""

          What the design needs from this:
            · a container role that holds one child per tab
            · a per-child name (title, or value — note which)
            · AXPress advertised, or the ordinal-chord fallback is required
            · a selected marker, so "which tab am I on" needs no second read
        """)
    }

    /// Depth-first collection of anything that LOOKS like a strip: a
    /// candidate role holding at least two children that carry a name. The
    /// two-child floor is what keeps a window's every AXGroup off the report
    /// without deciding in advance which role wins.
    private static func collect(
        _ element: AXUIElement,
        depth: Int,
        into found: inout [(element: AXUIElement, depth: Int)]
    ) {
        guard depth < 12, found.count < 8 else { return }
        let role = AX.string(element, kAXRoleAttribute) ?? ""
        let children = AX.children(element, kAXChildrenAttribute)

        if containerRoles.contains(role) {
            let named = children.filter {
                AX.string($0, kAXTitleAttribute)?.isEmpty == false
                    || AX.string($0, kAXValueAttribute)?.isEmpty == false
            }
            if named.count >= 2 { found.append((element, depth)) }
        }
        for child in children {
            collect(child, depth: depth + 1, into: &found)
        }
    }

    /// The ADVERTISED action list — what the element says it can do, which is
    /// not the same as what pressing it will accomplish. `PageElementActions`
    /// exists because web controls advertise AXPress and then ignore it; the
    /// list is a necessary condition, never a sufficient one.
    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }
}

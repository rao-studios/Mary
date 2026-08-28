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
//  What this prints, per container that could be a tab strip: the container's
//  role and depth, then each child's role, its name AND WHICH ATTRIBUTE gave
//  it, selected state, frame, and the advertised action list.
//
//  MEASURED 2026-08-28, macOS 26 — Chrome 151 and Safari, side by side. The
//  two browsers agree on exactly one thing:
//
//                      Chrome                     Safari
//    strip container   AXTabGroup                 AXOpaqueProviderGroup
//                                                   /AXOpaqueProviderList
//    strip depth       7–8 (deep in the chrome)   1 (a child of the window)
//    tab role          AXRadioButton/AXTabButton  ← the one agreement
//    tab NAME lives    AXDescription              AXTitle
//    AXPress           advertised                 advertised
//    which tab is on   AXSelected                 NOT PUBLISHED — the window
//                                                   title is the only signal
//    close affordance  child AXButton "Close"     custom action "close tab"
//
//  Three consequences the design took from this:
//
//   1. THE STRIP'S COORDINATES ARE PACKAGE DATA. A lane that searched for an
//      `AXTabGroup` by role would, in Safari, find the CONTENT container —
//      Safari's own AXTabGroup holds the page. Not a near miss: it would
//      return the page and call it the tab strip.
//   2. THE NAME LADDER MUST BE DECLARED, not assumed. This probe's first live
//      run reported "no tab strip" for Chrome because it read title and value
//      only. Nothing failed; the strip was simply invisible to it.
//   3. BOTH ADVERTISE AXPress, so a tab is addressable by IDENTITY and the
//      ordinal-chord fallback (⌘1…⌘9) is not needed for either. An ordinal is
//      a position, and a position is wrong the moment a tab moves — so this
//      measurement is what keeps it out of the common path.
//
//  Also measured: Safari publishes multi-line action NAMES on toolbar items
//  ("Name:…\nTarget:0x0\nSelector:(null)"), flattened for display below.
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
    /// MEASURED, and the reason the strip's coordinates are package data
    /// rather than a constant: the two browsers agree on the TAB and disagree
    /// on everything around it. Chrome nests an `AXTabGroup` seven or eight
    /// levels down; Safari hangs an `AXOpaqueProviderGroup` off the window
    /// itself, and its own `AXTabGroup` is the CONTENT container — so a lane
    /// that went looking for a tab group by role would, in Safari, find the
    /// page.
    static let containerRoles: Set<String> = [
        "AXTabGroup", "AXOpaqueProviderGroup", "AXToolbar", "AXRadioGroup",
        "AXGroup", "AXList",
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
                let childSubrole = AX.string(child, kAXSubroleAttribute)
                let named = Self.tabName(of: child)
                let selected = AX.number(child, kAXSelectedAttribute)?.boolValue
                let actions = actionNames(child)
                let frame = AX.frame(of: child)
                let closer = Self.axChildren(of: child).first { Self.tabName(of: $0)?.text == "Close" }

                let selectedMark = selected == true ? " ●selected"
                    : selected == nil ? " (no AXSelected)" : ""
                let press = actions.contains(kAXPressAction as String) ? "AXPress" : "NO AXPress"
                let geometry = frame.map {
                    String(format: "%.0f×%.0f", $0.width, $0.height)
                } ?? "no frame"

                print("""
                  │ \(index + 1). \(childRole)\(childSubrole.map { "/\($0)" } ?? "")  \
                \"\(named?.text ?? "—")\"  ← \(named?.attribute ?? "UNNAMED")\(selectedMark)
                  │    \(press)\(closer != nil ? " · has a Close child" : "") · \(geometry)
                  │    actions: \(actions.isEmpty ? "none" : actions.joined(separator: ", "))
                """)
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
        // THE TAB STRIP IS NATIVE CHROME AND NEVER LIVES INSIDE THE PAGE. A
        // walk that descends into the web area finds a page's own landmarks
        // and tab widgets and reports them as the browser's strip — which the
        // first run of this probe did, from a page that happened to be awake.
        // Stopping here is also what keeps the report stable: page content
        // changes with every navigation, chrome does not.
        guard role != "AXWebArea" else { return }
        let children = AX.children(element, kAXChildrenAttribute)

        if containerRoles.contains(role) {
            let named = children.filter { Self.tabName(of: $0) != nil }
            if named.count >= 2 { found.append((element, depth)) }
        }
        for child in children {
            collect(child, depth: depth + 1, into: &found)
        }
    }

    /// WHERE A TAB KEEPS ITS NAME, reported rather than assumed — the first
    /// live run of this probe found nothing at all because it read title and
    /// value only, and Chrome puts the name in DESCRIPTION. Which attribute
    /// answered is printed beside every row, because a roster that climbs the
    /// wrong ladder does not fail, it just sees an unnamed strip.
    static func tabName(of element: AXUIElement) -> (text: String, attribute: String)? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let text = AX.string(element, attribute), !text.isEmpty {
                return (text, attribute as String)
            }
        }
        return nil
    }

    static func axChildren(of element: AXUIElement) -> [AXUIElement] {
        AX.children(element, kAXChildrenAttribute)
    }

    /// The ADVERTISED action list — what the element says it can do, which is
    /// not the same as what pressing it will accomplish. `PageElementActions`
    /// exists because web controls advertise AXPress and then ignore it; the
    /// list is a necessary condition, never a sufficient one.
    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        // SAFARI PUBLISHES MULTI-LINE ACTION NAMES on its toolbar items —
        // whole "Name:…\nTarget:0x0\nSelector:(null)" blocks where a verb
        // belongs. Flattened to the first line so one browser's malformed
        // output cannot make the report unreadable for the other; an exact
        // `AXPress` match is unaffected either way.
        return list.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
    }
}

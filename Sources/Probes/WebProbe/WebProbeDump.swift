//
//  WebProbeDump.swift
//  WebProbe
//
//  THE WHOLE TREE, PRINTED, when a summary has stopped being enough.
//
//  Every other subcommand here answers a specific question and is shaped by
//  the answer it expects. This one is shaped by nothing: when the focused
//  Chrome window turned out to publish 74 nodes, no tab strip and no web
//  area, no amount of asking better questions would say WHAT it does publish.
//
//  Indented by depth, one line per node: role, subrole, title-or-value, and
//  the child count. `--window <n>` picks a window by the index `windows`
//  printed; `--depth <n>` bounds it.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin

enum WebProbeDump {

    static func run(_ application: NSRunningApplication, windowIndex: Int?, maxDepth: Int) async {
        let pid = application.processIdentifier
        let name = application.localizedName ?? "\(pid)"
        let element = AXUIElementCreateApplication(pid)
        let windows = AX.children(element, kAXWindowsAttribute)

        print("▸ \(name) (pid \(pid)) · \(windows.count) windows · depth ≤ \(maxDepth)")

        let chosen: [(offset: Int, element: AXUIElement)]
        if let windowIndex {
            guard windowIndex < windows.count else {
                print("  No window [\(windowIndex)] — there are \(windows.count).")
                return
            }
            chosen = [(windowIndex, windows[windowIndex])]
        } else if let focused = AX.element(element, kAXFocusedWindowAttribute) {
            let offset = windows.firstIndex { CFEqual($0, focused) } ?? 0
            chosen = [(offset, focused)]
        } else {
            chosen = Array(windows.enumerated()).map { ($0.offset, $0.element) }
        }

        for (offset, window) in chosen {
            print("\n[\(offset)] \(AX.string(window, kAXTitleAttribute) ?? "(untitled)")")
            dump(window, depth: 0, maxDepth: maxDepth)
        }
    }

    private static func dump(_ element: AXUIElement, depth: Int, maxDepth: Int) {
        let role = AX.string(element, kAXRoleAttribute) ?? "—"
        let subrole = AX.string(element, kAXSubroleAttribute)
        let title = AX.string(element, kAXTitleAttribute)
        let value = AX.string(element, kAXValueAttribute)
        let description = AX.string(element, kAXDescriptionAttribute)
        let children = AX.children(element, kAXChildrenAttribute)

        // Title first, then value, then description — the same ladder
        // PageElementReader climbs, so what prints here is what a reader
        // would have to work with.
        let label = title?.nilIfEmpty ?? value?.nilIfEmpty ?? description?.nilIfEmpty
        let source = title?.nilIfEmpty != nil ? "title"
            : value?.nilIfEmpty != nil ? "value"
            : description?.nilIfEmpty != nil ? "desc" : ""

        let indent = String(repeating: "  ", count: depth)
        let named = label.map { " \"\($0.prefix(60))\" (\(source))" } ?? ""
        let kids = children.isEmpty ? "" : "  [\(children.count)]"
        print("\(indent)\(role)\(subrole.map { "/\($0)" } ?? "")\(named)\(kids)")

        guard depth < maxDepth else {
            if !children.isEmpty { print("\(indent)  … \(children.count) more, past --depth") }
            return
        }
        for child in children {
            dump(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

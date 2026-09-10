//
//  main.swift
//  AXProbe
//
//  WHAT: What Mary actually sees — real AXEngine.ambientContext walk.
//  OUT:  CLI: swift run mary-ax-probe [--app|--pid|--json|--tree|--watch]
//  PIN:  Run signed (scripts/dev.sh); ad-hoc AX grant dies on rebuild.
//

import AppKit
import ApplicationServices
import Foundation
import MaryPlugin
import MaryAmbient
import MaryComputerUse
import MaryFoundation

// MARK: - Arguments

let arguments = CommandLine.arguments
func flag(_ name: String) -> Bool { arguments.contains(name) }
func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
    else { return nil }
    return arguments[index + 1]
}

if WatchProbe.shouldRun(arguments) {
    // Watching, not walking: this lane never touches another application.
    await WatchProbe.run(arguments)
    exit(0)
}

if ProseProbe.shouldRun(arguments) {
    // The prose lane's own probe — a different question from the surface
    // walk below, and it may write, so it never runs by default.
    await ProseProbe.run(arguments)
}

guard AXIsProcessTrusted() else {
    print("""
    Accessibility is not granted for this binary.

    System Settings → Privacy & Security → Accessibility, then add the binary
    this ran from. If you granted it already and it stopped working, the build
    was signed ad-hoc: use ./scripts/dev.sh, which re-signs with a stable
    identity so one grant survives rebuilds.
    """)
    exit(1)
}

// MARK: - Target

let target: NSRunningApplication? = {
    if let raw = value("--pid"), let pid = pid_t(raw) {
        return NSRunningApplication(processIdentifier: pid)
    }
    if let name = value("--app")?.lowercased() {
        // Localized name, then prefix — not a substring of the bundle id.
        return NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased() == name
        } ?? NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().hasPrefix(name)
        }
    }
    return NSWorkspace.shared.frontmostApplication
}()

guard let application = target, let name = application.localizedName else {
    print("No such application. Try --app <name> or --pid <n>.")
    exit(1)
}

let pid = application.processIdentifier
print("▸ \(name) (pid \(pid), \(application.bundleIdentifier ?? "no bundle id"))")

// MARK: - The walk

let started = Date()
guard let context = AXEngine.ambientContext(pid: pid) else {
    print("The walk returned nothing — the process may have exited, or exposes no windows.")
    exit(1)
}
let walked = Date().timeIntervalSince(started)

print("""

  walk        \(String(format: "%.0f", walked * 1000)) ms · \
\(context.capture.nodeCount) nodes\(context.capture.isTruncated ? " · truncated" : "")
  window      \(context.activeWindow?.title ?? "—")
  elements    \(context.elements.count) published (\(context.scope.rawValue))
  focused     \(context.focused.map { "\($0.role) \($0.label ?? "")" } ?? "—")
""")

// THE HONEST BLIND SPOT, said out loud rather than left to be discovered.
if context.webContentHost {
    print("""

  ⚠︎ This process hosts web content. Chromium and Electron build no
    web-content accessibility hierarchy until an assistive client asks, so
    what is published above is the native shell — the page itself is not in
    it — typically one element published where a hundred-odd exist. The wake
    lane that fixes this is deferred; the surface marks it `pageNotYetRead`
    rather than claiming to have read a page.
""")
}

// MARK: - The surface, as the store would hold it

// Identity-bearing applicationPlace, not the shared applications lane.
let place = AmbientPlaceResolver.applicationPlace(
    forBundleID: application.bundleIdentifier ?? "\(pid)")
let surface = AmbientBridge.surface(from: context, place: place)

print("""

  place       \(place.token)
  surface     \(surface.surfaceLine(at: Date()))
""")

if !surface.elements.isEmpty {
    print("\n  roster")
    for element in surface.elements.prefix(12) {
        let frame = element.frame.map {
            String(format: "(%.0f, %.0f  %.0f×%.0f)",
                   $0.rect.x, $0.rect.y, $0.rect.width, $0.rect.height)
        } ?? "no frame"
        print("    \(element.ordinal). \(element.kind) \"\(element.label)\"  \(frame)")
        print("       identity: \(element.identity)")
    }
    if surface.elements.count > 12 {
        print("    … \(surface.elements.count - 12) more")
    }
}

// MARK: - The record an action would carry

if let record = ActedElementReader.focusedElement(pid: pid) {
    print("""

  acted-element record (what a Skill's `target` would hold)
    identity  \(record.identity)
    kind      \(record.kind)
    window    \(record.windowTitle)
    frame     \(String(format: "%.0f, %.0f  %.0f×%.0f",
                       record.frame.rect.x, record.frame.rect.y,
                       record.frame.rect.width, record.frame.rect.height))
    screen    \(record.frame.screen.map { "#\($0.index)" } ?? "—")
""")

    // Live identity parity: walk label vs focused read.
    if let walkedFocused = surface.elements.first(where: \.isFocused) {
        let agrees = walkedFocused.identity == record.identity
        print("    parity   \(agrees ? "✓ matches the walked element" : "✗ MISMATCH")")
        if !agrees {
            print("             walk: \(walkedFocused.identity)")
            print("             act:  \(record.identity)")
        }
    }

    if flag("--json"), let json = AXFrameProjection.json(record, prettyPrinted: true) {
        print("\n\(json)")
    }
} else {
    print("\n  acted-element record — none (nothing focused)")
}

// THE RAW TREE, for measuring an application's chrome before writing a package that
// names its controls. The roster above publishes only what Mary would OFFER; a
// declaration has to be written against what is actually there, including the
// containers and the unlabeled nodes the roster drops.
if flag("--tree"), let snapshot = AXEngine.snapshot(
    pid: application.processIdentifier, options: .exhaustive) {
    print("\n  ── tree ──────────────────────────────────────")
    let match = value("--role")?.lowercased()
    for window in snapshot.windows {
        print("  window \"\(window.title)\" \(window.frame.map(describe) ?? "")")
        guard let root = window.root else { continue }
        root.forEachNode(withAncestors: { node, ancestors in
            let depth = ancestors.count
            if let match, !node.role.lowercased().contains(match),
               !(node.label?.lowercased().contains(match) ?? false) { return }
            let indent = String(repeating: "  ", count: min(depth, 12) + 1)
            let label = node.label.map { " \"\($0)\"" } ?? ""
            let subrole = node.subrole.map { " <\($0)>" } ?? ""
            print("\(indent)\(node.role)\(subrole)\(label) \(node.frame.map(describe) ?? "")")
        })
        if snapshot.windows.count > 1 { print("") }
    }
}

func describe(_ frame: CGRect) -> String {
    "(\(Int(frame.minX)), \(Int(frame.minY))  \(Int(frame.width))×\(Int(frame.height)))"
}

// What this walk cost the machine layer, and anything it refused along the way.
print("\n\(WatchProbe.render(ComputerUseMonitor.shared.snapshot()))")

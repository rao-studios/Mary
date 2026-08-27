//
//  main.swift
//  AXProbe
//
//  WHAT MARY ACTUALLY SEES, printed.
//
//  Every test in the adapter layer runs against a synthetic tree, because a
//  test that needs a live accessibility grant either mocks the framework or
//  passes on one machine and fails on another. That leaves exactly one
//  question unanswered by the suite, and it is the important one: does the
//  engine see a real application correctly?
//
//  This probe answers it by driving the REAL path — the same
//  `AXEngine.ambientContext` walk the tier-0 observer performs, the same
//  bridge into an `AmbientSurface`, the same `AXElementRecord` an action's
//  target will carry. Not a second implementation for diagnosis; that is the
//  whole design. Three readers, one truth.
//
//    swift run mary-ax-probe                 # the frontmost application
//    swift run mary-ax-probe --app TextEdit  # by name
//    swift run mary-ax-probe --pid 4321
//    swift run mary-ax-probe --json          # the focused element's record
//
//  RUN IT THROUGH `scripts/dev.sh` OR A SIGNED BUILD. An ad-hoc binary's
//  accessibility grant does not survive a rebuild, so a bare `swift run` will
//  report "not trusted" on the second try and look like a regression in the
//  engine.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAdapters
import MaryAmbient
import MaryFoundation

// MARK: - Arguments

let arguments = CommandLine.arguments
func flag(_ name: String) -> Bool { arguments.contains(name) }
func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
    else { return nil }
    return arguments[index + 1]
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
        // Matched on the LOCALIZED NAME, and by prefix, because a bundle id is
        // the thing a person is least likely to have to hand — and because
        // "--app Code" matching Xcode by substring is a real way to spend ten
        // minutes debugging the wrong process.
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

// THE SAME LADDER THE OBSERVER CALLS, and the distinction is not academic:
// `factPlace(forBundleID:)` answers with the shared applications LANE — the fact
// pool for genuinely-unknown processes — while this one is identity-bearing.
// Calling the wrong one here would make the probe report every application as
// the same place, which is exactly the collision the identity ladder exists
// to prevent, and the probe would be lying about a bug it does not have.
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

    // THE PARITY CHECK, live. The tests pin that the two paths spell identity
    // the same way against a synthetic tree; this is the same claim against a
    // real one, where the label a walk reads and the label a focused read
    // reads could differ in ways no fixture would show.
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

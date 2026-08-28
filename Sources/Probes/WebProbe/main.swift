//
//  main.swift
//  WebProbe
//
//  WHAT A BROWSER ACTUALLY EXPOSES, measured rather than assumed.
//
//  The web lane is the one part of the engine whose facts cannot be learned
//  from a fixture, because every interesting question is about a program Mary
//  does not control: does this browser build a page tree at all, how long
//  after being asked, what shape does it give its tab strip, and can a tab be
//  pressed. A synthetic tree answers each of those with whatever the person
//  writing it already believed.
//
//  So this probe comes FIRST, before the lane that depends on it. Its output
//  is the input to a design decision, and the numbers it prints belong in the
//  headers of the files that ride them.
//
//    mary-web-probe wake [--app <name> | --pid <n> | --bundle <id>]
//        Sends both wake signals, reports each return code AND the time until
//        a web area appears. The return codes are the part the shipped code
//        deliberately discards, so this is the only place they are visible.
//
//    mary-web-probe tabs [--app <name> | --pid <n>]
//        Dumps the tab strip: containers, the roles their children carry,
//        titles, selected state, and whether AXPress is advertised. This is
//        the measurement the tab roster's design waits on.
//
//    mary-web-probe settle <url> [--app <name>]
//        Opens a URL and watches the signals a load-settle check could use:
//        web-area presence, whether AXURL is readable on this engine, and how
//        long title and child-count take to stop moving.
//
//  RUN IT THROUGH `scripts/dev.sh` OR A SIGNED BUILD. An ad-hoc binary's
//  accessibility grant does not survive a rebuild, so a bare `swift run` will
//  report "not trusted" on the second try and look like a regression.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin

let arguments = CommandLine.arguments
let verb = arguments.count > 1 ? arguments[1] : ""

func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
    else { return nil }
    return arguments[index + 1]
}

func usage() -> Never {
    print("""
    mary-web-probe — what a browser actually exposes

      wake    [--app <name> | --pid <n> | --bundle <id>]  wake signals + timing
      tabs    [--app <name> | --pid <n>]                  the tab strip's AX shape
      windows [--app <name> | --pid <n>]                  where the page is, vs where the lane looks
      lane                                                does the browsing lane load and offer its skills
      roster  [--switch <name|ordinal>]                    the tab roster, through the shipped code
      address [--set <url>]                              can the address bar be SET, not typed
      page-text [--bytes <n>]                             the page as prose, via AX
      dump    [--window <n>] [--depth <n>]                the whole tree, printed
      settle  <url> [--app <name>]                        load-settle signals

    With no --app/--pid the frontmost application is used.
    """)
    exit(verb.isEmpty ? 1 : 0)
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

/// Resolve the target the same way `mary-ax-probe` does — by pid, by
/// localized name (exact then prefix), by bundle id, or the frontmost app.
func resolveTarget() -> NSRunningApplication? {
    if let raw = value("--pid"), let pid = pid_t(raw) {
        return NSRunningApplication(processIdentifier: pid)
    }
    if let bundle = value("--bundle") {
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }
    if let name = value("--app")?.lowercased() {
        return NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased() == name
        } ?? NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().hasPrefix(name)
        }
    }
    return NSWorkspace.shared.frontmostApplication
}

switch verb {
case "wake":
    guard let application = resolveTarget() else {
        print("No such application. Try --app <name>, --pid <n> or --bundle <id>.")
        exit(1)
    }
    await WebProbeWake.run(application)

case "tabs":
    guard let application = resolveTarget() else {
        print("No such application. Try --app <name> or --pid <n>.")
        exit(1)
    }
    await WebProbeTabs.run(application)

case "windows":
    guard let application = resolveTarget() else {
        print("No such application. Try --app <name> or --pid <n>.")
        exit(1)
    }
    await WebProbeWindows.run(application)

case "lane":
    await WebProbeLane.run()

case "roster":
    guard let application = resolveTarget() else {
        print("No such application. Try --app <name> or --pid <n>.")
        exit(1)
    }
    await WebProbeRoster.run(application, switchTo: value("--switch"))

case "address":
    guard let application = resolveTarget() else {
        print("No such application. Try --app <name> or --pid <n>.")
        exit(1)
    }
    await WebProbeAddress.run(application, set: value("--set"))

case "page-text":
    guard let application = resolveTarget() else {
        print("No such application. Try --app <name> or --pid <n>.")
        exit(1)
    }
    await WebProbePageText.run(
        application, byteLimit: value("--bytes").flatMap(Int.init) ?? 8000)

case "dump":
    guard let application = resolveTarget() else {
        print("No such application. Try --app <name> or --pid <n>.")
        exit(1)
    }
    await WebProbeDump.run(
        application,
        windowIndex: value("--window").flatMap(Int.init),
        maxDepth: value("--depth").flatMap(Int.init) ?? 6)

case "settle":
    guard arguments.count > 2, !arguments[2].hasPrefix("--") else {
        print("settle needs a URL: mary-web-probe settle https://example.com")
        exit(1)
    }
    await WebProbeSettle.run(url: arguments[2], application: resolveTarget())

default:
    usage()
}

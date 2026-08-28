//
//  WebProbeRoster.swift
//  WebProbe
//
//  THE TAB ROSTER, THROUGH THE SHIPPED CODE — the join no unit test can make.
//
//  `BrowserTabRosterTests` pins the assembly and resolution rules against
//  fixtures, and those rules are correct in the abstract. What a fixture
//  cannot say is whether the DECLARATION matches the browser: whether the
//  strip is really at that role, whether tabs really name themselves in that
//  attribute, whether pressing one really switches. Those are claims about
//  somebody else's program, and only a live run settles them.
//
//  The declarations below are the ones the shipped packages will carry, from
//  the `tabs` measurements. Running this against both browsers is what proves
//  a package right before it is written — and if a browser changes its mind
//  in some future version, this is the file that says so first.
//
//    mary-web-probe roster [--app <name>]        read the strip
//    mary-web-probe roster --switch "wiki"       switch by name, and prove it
//    mary-web-probe roster --switch 3            switch by ordinal
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import MaryPlugin

enum WebProbeRoster {

    /// MEASURED 2026-08-28 on macOS 26. These are candidate package data,
    /// living here until `chrome.mary` and `safari.mary` carry them — and
    /// deliberately keyed by the shape of the browser rather than its name,
    /// because that is how the real declaration will select too.
    static func surface(forBundleID bundleID: String) -> PluginBrowserSurfaceSchema? {
        switch WebContentHost.classify(pid: 0, bundleID: bundleID) {
        case .chromium:
            return .init(
                tabStripRole: "AXTabGroup",
                tabNameAttribute: .description,
                tabNameNoiseMarkers: ["Memory usage"],
                selectionSignal: .selectedAttribute,
                closeAffordance: .childButton,
                closeControlLabel: "Close",
                newTabChord: .init(key: .t, modifiers: [.command]),
                closeTabChord: .init(key: .w, modifiers: [.command]))
        case .webkit:
            return .init(
                tabStripRole: "AXOpaqueProviderGroup",
                tabStripSubrole: "AXOpaqueProviderList",
                tabNameAttribute: .title,
                selectionSignal: .windowTitle,
                closeAffordance: .elementAction,
                closeControlLabel: "close tab",
                newTabChord: .init(key: .t, modifiers: [.command]),
                closeTabChord: .init(key: .w, modifiers: [.command]))
        case .electron, .none:
            return nil
        }
    }

    static func run(_ application: NSRunningApplication, switchTo: String?) async {
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier ?? ""
        let name = application.localizedName ?? "\(pid)"

        print("▸ \(name) (pid \(pid), \(bundleID))")

        guard let surface = surface(forBundleID: bundleID) else {
            print("  No candidate declaration for this browser.")
            return
        }
        print("""
          declared    strip \(surface.tabStripRole)\
        \(surface.tabStripSubrole.map { "/\($0)" } ?? "") · \
        name in \(surface.tabNameAttribute.rawValue) · \
        current by \(surface.selectionSignal.rawValue)
        """)

        _ = await BrowserAXReadiness.ensureWebContentAX(pid: pid, bundleID: bundleID)

        let started = Date()
        let tabs = BrowserTabRoster.read(pid: pid, surface: surface)
        let elapsed = Date().timeIntervalSince(started)

        guard !tabs.isEmpty else {
            print("""

              NO STRIP FOUND. The declaration above does not match this
              browser's tree — which is the finding, and it changes the
              package rather than the roster.
            """)
            return
        }

        print(String(format: "  read        %.0f ms · %d tabs\n", elapsed * 1000, tabs.count))
        for tab in tabs {
            let mark = switch tab.isCurrent {
            case true: "●"
            case false: " "
            default: "?"
            }
            print("  \(mark) \(tab.ordinal). \(tab.name)")
        }
        if tabs.allSatisfy({ $0.isCurrent == nil }) {
            print("""

              ⚠︎ NO TAB READS AS CURRENT — either the declared signal is wrong
                for this browser, or (for the title signal) two tabs show
                identically-titled pages. Reported as unknown rather than as
                "none", which is the distinction that matters.
            """)
        }

        guard let switchTo else {
            print("\n  Pass --switch <name|ordinal> to switch, and prove it landed.")
            return
        }

        let target: BrowserTabRoster.Target = Int(switchTo)
            .map { .ordinal($0) } ?? .named(switchTo)
        print("\n  switching to \(target)…")

        // Through the shipped path, including its own confirmation.
        let outcome = await BrowserTabRoster.activate(target, pid: pid, surface: surface)
        print("  outcome     \(outcome)")

        let after = BrowserTabRoster.read(pid: pid, surface: surface)
        let current = after.first { $0.isCurrent == true }
        print("  now on      \(current?.name ?? "—")")
        print("  window      \(WebSurface.windowTitle(pid: pid) ?? "—")")
    }
}

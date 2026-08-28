//
//  WebProbeSettle.swift
//  WebProbe
//
//  WHEN IS A PAGE LOADED, without asking the browser?
//
//  The predecessor asked over AppleScript and got a real answer from the
//  browser's own scripting dictionary. Mary cannot ask, so a load has to be
//  INFERRED from what Accessibility shows — and an inference needs to be
//  measured before it can be trusted, because the failure mode is silent: a
//  settle check that fires early makes every downstream read look flaky, and
//  one that never fires makes every navigation look broken.
//
//  This watches four signals through a real navigation and prints when each
//  stops moving:
//
//    • a web area exists at all
//    • AXURL on the web area — readable on this engine, or not
//    • the front window's title
//    • the web area's direct child count
//
//  The design question it settles: is "title and child count both unchanged
//  across two consecutive polls" a sufficient proxy for loaded? A page that
//  animates forever (an SPA with a live feed) will never satisfy it, which is
//  why the verdict this feeds has a `presentButChurning` case rather than a
//  boolean — but the frequency of that case is a fact, not a guess.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin

enum WebProbeSettle {

    static let pollInterval: Duration = .milliseconds(500)
    static let budget: TimeInterval = 20

    struct Sample {
        var at: TimeInterval
        var hasWebArea: Bool
        var url: String?
        var title: String?
        var childCount: Int
    }

    static func run(url: String, application: NSRunningApplication?) async {
        guard let application else {
            print("No such application. Try --app <name>.")
            return
        }
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier
        let name = application.localizedName ?? "\(pid)"

        print("▸ \(name) (pid \(pid)) ← \(url)")

        // Navigation by `/usr/bin/open`, which is the road the shipped lane
        // takes: atomic, no frontmost stage required, and no keystroke that
        // could land in a page if focus moves mid-type. It talks to Launch
        // Services, not to the browser over Apple Events.
        do {
            let result = try await Subprocess.run(
                "/usr/bin/open",
                bundleID.map { ["-b", $0, url] } ?? [url],
                timeout: 15)
            if result.exitCode != 0 {
                print("  open failed (\(result.exitCode)): \(result.output)")
                return
            }
        } catch {
            print("  open failed: \(error.localizedDescription)")
            return
        }

        let readiness = await BrowserAXReadiness.ensureWebContentAX(
            pid: pid, bundleID: bundleID)
        print("  readiness   \(readiness)")

        let element = AXUIElementCreateApplication(pid)
        let started = Date()
        var samples: [Sample] = []
        var settledAt: TimeInterval?

        while Date().timeIntervalSince(started) < budget {
            let area = WebProbeWake.webArea(of: element)
            let window = AX.element(element, kAXFocusedWindowAttribute)
                ?? AX.element(element, kAXMainWindowAttribute)
            let sample = Sample(
                at: Date().timeIntervalSince(started),
                hasWebArea: area != nil,
                url: area.flatMap { AX.string($0, "AXURL") },
                title: window.flatMap { AX.string($0, kAXTitleAttribute) },
                childCount: area.map { AX.children($0, kAXChildrenAttribute).count } ?? 0)
            samples.append(sample)

            // The candidate rule, evaluated live: two consecutive polls where
            // a web area is present and neither the title nor the child count
            // moved.
            if settledAt == nil, samples.count >= 2 {
                let previous = samples[samples.count - 2]
                if sample.hasWebArea, previous.hasWebArea,
                   sample.title == previous.title,
                   sample.childCount == previous.childCount {
                    settledAt = sample.at
                }
            }
            try? await Task.sleep(for: pollInterval)
        }

        print("\n  t(s)   web  children  url                       title")
        for sample in samples {
            let url = sample.url.map { String($0.prefix(24)) } ?? "—"
            let title = sample.title.map { String($0.prefix(28)) } ?? "—"
            print(String(format: "  %5.1f  %@   %6d   %-24@  %@",
                         sample.at, sample.hasWebArea ? "✓" : "·",
                         sample.childCount, url as NSString, title))
        }

        let urlReadable = samples.contains { $0.url?.isEmpty == false }
        print("""

          AXURL       \(urlReadable
                        ? "READABLE on this engine — the settle check can match the host"
                        : "NOT readable — the settle check must rely on quiescence alone")
          settled     \(settledAt.map { String(format: "%.1f s", $0) }
                        ?? "NEVER within \(Int(budget)) s — this page keeps moving, "
                         + "which is the `presentButChurning` case")
        """)
    }
}

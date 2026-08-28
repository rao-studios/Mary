//
//  WebProbePageText.swift
//  WebProbe
//
//  THE PAGE READ, AGAINST A REAL PAGE — the claim `WebPageText` exists to
//  make, checked where fixtures cannot reach.
//
//  Its unit tests pin the RULES (document order, dedup, the parent-defers-to-
//  child rule, both budgets) on synthetic trees, and those rules are all
//  correct in the abstract. What no fixture can say is whether a real page's
//  accessibility tree carries its words at all, or in which attribute, or
//  buried under how much furniture. This prints the answer for whatever is on
//  screen.
//
//  The reading to look for: does it sound like the page? Chrome is the case
//  worth running, because the predecessor could never read a Chrome page —
//  its scripting dictionary has no text property and its only other channel
//  is a JavaScript toggle the doctrine refuses. If this prints prose from
//  Chrome, the AX road is not a workaround for the lost one, it is wider.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin

enum WebProbePageText {

    static func run(_ application: NSRunningApplication, byteLimit: Int) async {
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier
        let name = application.localizedName ?? "\(pid)"

        print("▸ \(name) (pid \(pid), \(bundleID ?? "no bundle id"))")

        let readiness = await BrowserAXReadiness.ensureWebContentAX(
            pid: pid, bundleID: bundleID)
        print("  readiness   \(readiness)")

        let started = Date()
        guard let reading = WebPageText.read(
            inApp: AXUIElementCreateApplication(pid), byteLimit: byteLimit) else {
            print("""

              NO WEB AREA in the focused window. That is `read` returning nil,
              which a caller must tell apart from an empty reading — the
              readiness line above is how.
            """)
            return
        }
        let elapsed = Date().timeIntervalSince(started)

        print(String(
            format: "  read        %.0f ms · %d lines · %d bytes%@",
            elapsed * 1000, reading.contributingNodes,
            reading.text.utf8.count, reading.truncated ? " · TRUNCATED" : ""))

        if reading.contributingNodes == 0 {
            print("""

              A PAGE WITH NO WORDS — an empty reading, not a missing one. Real
              for a canvas app or a tree still filling in, and the count above
              is what says which of the two a caller is looking at.
            """)
            return
        }

        print("\n" + reading.text)
    }
}

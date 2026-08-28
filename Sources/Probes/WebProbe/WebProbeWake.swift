//
//  WebProbeWake.swift
//  WebProbe
//
//  THE MEASUREMENT THE SHIPPED CODE THROWS AWAY. `WebAXWakeup` sends both
//  wake attributes and ignores both return codes on purpose — between Chrome
//  and Electron each host implements the one the other refuses, so a return
//  code is not evidence about whether the tree will arrive. That is right for
//  production and useless for learning what this machine's browsers actually
//  do, which is what this subcommand is for.
//
//  It measures TWICE, and the pair is the point:
//    1. Raw: send each attribute separately, print its OSStatus, then poll for
//       the web area and time its arrival.
//    2. Shipped: call `BrowserAXReadiness.ensureWebContentAX` — the same door
//       every caller uses — and print its verdict. If the raw half finds a
//       page and the shipped half says `.axTreeAbsent`, the bug is ours.
//
//  A SECOND RUN ON AN AWAKE PROCESS REPORTS ~0 ms, and that is not a faster
//  wake — Chromium stays awake for the process's lifetime, so the honest way
//  to re-measure a cold wake is to quit and reopen the browser first.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryPlugin

enum WebProbeWake {

    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedInterface = "AXEnhancedUserInterface"
    static let pollInterval: Duration = .milliseconds(100)
    static let budget: TimeInterval = 15

    static func run(_ application: NSRunningApplication) async {
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier
        let name = application.localizedName ?? "\(pid)"
        let kind = WebContentHost.classify(pid: pid, bundleID: bundleID)

        print("""
        ▸ \(name) (pid \(pid), \(bundleID ?? "no bundle id"))
          host        \(kind.rawValue)\(kind == .none ? "  — no web-content evidence; nothing will be sent" : "")
        """)

        let element = AXUIElementCreateApplication(pid)

        if webArea(of: element) != nil {
            print("""
              state       ALREADY AWAKE — a web area answers before any signal.
                          Chromium stays awake for the process's lifetime, so
                          quit and reopen \(name) to measure a cold wake.
            """)
        } else {
            // Separately, so each attribute's own answer is visible. The
            // shipped code sends both in one breath and reads neither.
            let manual = AXUIElementSetAttributeValue(
                element, manualAccessibility as CFString, kCFBooleanTrue)
            let enhanced = AXUIElementSetAttributeValue(
                element, enhancedInterface as CFString, kCFBooleanTrue)

            print("""
              \(manualAccessibility)
                          \(describe(manual))
              \(enhancedInterface)
                          \(describe(enhanced))
            """)

            let started = Date()
            var arrived: TimeInterval?
            while Date().timeIntervalSince(started) < budget {
                if webArea(of: element) != nil {
                    arrived = Date().timeIntervalSince(started)
                    break
                }
                try? await Task.sleep(for: pollInterval)
            }

            if let arrived {
                print(String(format: "  web area    arrived after %.2f s", arrived))
            } else {
                print("  web area    NEVER APPEARED within \(Int(budget)) s")
            }
        }

        // The shipped door, on the same process, so a disagreement between
        // the two halves is visible here rather than in a skill's refusal.
        let started = Date()
        let verdict = await BrowserAXReadiness.ensureWebContentAX(
            pid: pid, bundleID: bundleID)
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "  shipped     %@ (%.2f s via BrowserAXReadiness)",
                     String(describing: verdict), elapsed))

        if kind == .none, verdict == .notNeeded, webArea(of: element) != nil {
            print("""

              ⚠︎ This process exposes a web area but classifies `.none`, so the
                wake lane will never touch it. That is the known unseeded-host
                gap in WebContentHost — harmless here (the tree is already up),
                but it is the shape a missing seed takes.
            """)
        }
    }

    /// The probe's own web-area search. `WebAreaLocator` is internal to
    /// MaryPlugin, and a probe is not a reason to widen it — the walk is a
    /// dozen lines and this one deliberately looks at EVERY window rather
    /// than focused-or-main, so "the tree is up but not in the front window"
    /// is a state the probe can see and the lane's verdict cannot.
    static func webArea(of application: AXUIElement) -> AXUIElement? {
        let windows = AX.children(application, kAXWindowsAttribute)
        for window in windows {
            if let found = firstWebArea(in: window, depth: 0) { return found }
        }
        return nil
    }

    private static func firstWebArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 24 else { return nil }
        if AX.string(element, kAXRoleAttribute) == "AXWebArea" { return element }
        for child in AX.children(element, kAXChildrenAttribute) {
            if let found = firstWebArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Name the codes this lane actually meets. An unnamed `-25205` sends the
    /// reader to a header file; the two that matter are the whole story.
    static func describe(_ status: AXError) -> String {
        switch status.rawValue {
        case 0:
            return "0 (success) — this host implements the attribute"
        case -25205:
            return "-25205 (attributeUnsupported) — refused outright"
        case -25208:
            return "-25208 (notImplemented) — refused, and may wake anyway"
        default:
            return "\(status.rawValue)"
        }
    }
}

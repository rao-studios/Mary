//
//  WebAXWakeup.swift
//  MaryPlugin
//
//  THE AX ENGINE / WEB SUB-ENGINE — see AXEngine.swift for the directory's
//  doctrine header and Web/WebContentHost.swift for who is eligible to be
//  woken at all.
//
//  A CHROMIUM ACCESSIBILITY TREE IS OPT-IN. Chromium does not build its
//  web-content AX hierarchy until an assistive client announces itself.
//  Until then every `AXWebArea` walk returns nothing, and that nothing is
//  INDISTINGUISHABLE from "there is no page here". This file makes the
//  distinction: it asks for the tree, waits for it to materialize, and
//  answers with a verdict a caller can speak.
//
//  WHICH SIGNAL ACTUALLY WORKS — MEASURED against Chrome 151.0.7922.109 on
//  2026-08-12, by controlled comparison, because the documented answer is no
//  longer the true one:
//
//    • `AXManualAccessibility` — the historically documented switch — now
//      returns **-25205 (kAXErrorAttributeUnsupported)**. Setting it alone
//      and then polling for fifteen seconds produced NO web area, ever.
//    • `AXEnhancedUserInterface` IS in Chrome's advertised attribute list.
//      Setting it returns **-25208 (kAXErrorNotImplemented)** — and the web
//      area appears **2.3 seconds later** regardless. Chrome ignores the
//      attribute's semantics but treats the REQUEST as an assistive client
//      announcing itself.
//    • Once awake it STAYS awake for that process's lifetime.
//
//  ELECTRON IS THE SAME LAZY TREE THROUGH THE OTHER DOOR — MEASURED against
//  Obsidian (Electron, `md.obsidian`) on 2026-08-25, and it is the exact
//  MIRROR of Chrome:
//
//    • `AXManualAccessibility` returns **0 (success)**. The signal Chrome 151
//      refuses outright is the one Electron actually implements.
//    • `AXEnhancedUserInterface` returns the same **-25208 (notImplemented)**.
//    • The web area appeared **0.31 seconds** later — an order of magnitude
//      faster than Chrome's 2.3s, so the six-second budget is generous here
//      rather than tight.
//    • The signals go to the app's MAIN pid, the same one `AXWindowRoster`
//      enumerates windows from. Electron's renderer helper processes have
//      their own pids and need nothing sent to them.
//
//  That mirror is the whole argument for sending BOTH and trusting NEITHER
//  return code: between them these two hosts implement one attribute each,
//  and they do not agree on which. The settle poll is the only verdict true
//  for both. `mary-web-probe wake <bundle-id>` re-measures all of it.
//
//  THE SIDE-EFFECT CONCERN, and why it is bounded: `AXEnhancedUserInterface`
//  is the flag that makes some AppKit apps re-layout their windows. Chrome
//  reports it unimplemented, so nothing is applied — and nothing reaches this
//  file at all without positive web-host evidence from `WebContentHost`,
//  whose last rung is `.none` rather than "try anyway". That classifier gate
//  IS the blast radius.
//
//  ONE DELIBERATE DELTA FROM THE PREDECESSOR: it carried an `enabledPids`
//  memo that nothing ever read — written to be a hot-path skip for the settle
//  poll and never wired up. A dead set is preserved across a rewrite only
//  when its history is there to explain it; here it would arrive as new code
//  that does nothing, so it is not carried. The cheap early return below
//  (a web area already answers) is what a repeat caller actually rides.
//

import ApplicationServices
import Foundation

enum WebAXWakeup {

    static let manualAccessibilityAttribute = "AXManualAccessibility"
    /// The signal Chrome 151 actually wakes on. See the header: the set
    /// reports notImplemented and the tree arrives anyway.
    static let enhancedInterfaceAttribute = "AXEnhancedUserInterface"

    /// How often the settle loop looks for the tree. Chrome's 2.3s and
    /// Electron's 0.31s both quantize acceptably here, and a tighter poll
    /// would spend IPC on a walk that is already budgeted.
    static let pollInterval: Duration = .milliseconds(250)

    /// The pure gate, so "who gets woken" has exactly one definition. WebKit's
    /// tree is already up and `.none` has no evidence it should be poked —
    /// both are `.notNeeded`, for opposite reasons.
    static func needsWake(_ kind: WebContentHost.Kind) -> Bool {
        switch kind {
        case .chromium, .electron:
            return true
        case .webkit, .none:
            return false
        }
    }

    /// Ask the app behind `pid` for its web-content tree and wait for it.
    ///
    /// Sized to the measurement: the tree appeared 2.3s after the request, so
    /// a three-second budget was margin-free and a slow machine would have
    /// reported a page as unreachable that was merely still building.
    static func ensure(
        pid: pid_t,
        timeout: TimeInterval
    ) async -> BrowserAXReadiness.Readiness {
        let application = AXUIElementCreateApplication(pid)
        if WebAreaLocator.firstWebArea(inApp: application) != nil { return .ready }

        // BOTH signals, and the result codes deliberately ignored: Chrome 151
        // refuses the first and half-refuses the second, then wakes; Electron
        // accepts the first and refuses the second. Each host implements the
        // attribute the other does not. The poll below is the only honest
        // verdict for either.
        AXUIElementSetAttributeValue(
            application, manualAccessibilityAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            application, enhancedInterfaceAttribute as CFString, kCFBooleanTrue)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return .axTreeAbsent }
            if WebAreaLocator.firstWebArea(inApp: application) != nil { return .ready }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return .axTreeAbsent
            }
        }
        // One last look: the loop can exit on the deadline in the same beat
        // the tree arrives, and reporting absence then would be wrong by
        // milliseconds.
        return WebAreaLocator.firstWebArea(inApp: application) != nil ? .ready : .axTreeAbsent
    }
}

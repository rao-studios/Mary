//
//  WebAXWakeup.swift
//  MaryComputerUse
//
//  WHAT: Ask a lazy web host to build its accessibility tree, and wait for it.
//  IN:   WebContentHost.classify — the blast radius, not an allowlist
//  OUT:  BrowserAXReadiness / PageReaderLane.accessibility
//  PIN:  A CHROMIUM ACCESSIBILITY TREE IS OPT-IN, AND ITS ABSENCE LOOKS EXACTLY
//        LIKE AN EMPTY PAGE. Every `AXWebArea` walk returns nothing until an
//        assistive client announces itself, so a page full of links reads as a
//        page with nothing on it — which is how "click the first link" came to
//        be answered by pixels alone, naming rows "link 1" and "star".
//
//        WHICH SIGNAL ACTUALLY WORKS, ported from the reference port's measured
//        comparison (Chrome 151.0.7922.109, 2026-08-12) and RE-MEASURED here
//        before this file was trusted (live browsing round 4; `docs/browser-engine.md`):
//
//          • `AXManualAccessibility` — the historically documented switch — is
//            refused by Chrome outright (-25205, attributeUnsupported).
//          • `AXEnhancedUserInterface` is in Chrome's advertised list, returns
//            -25208 (notImplemented), and the web area appears ~2.3s later
//            anyway: Chrome ignores the attribute's semantics and treats the
//            REQUEST as an assistive client announcing itself.
//          • Electron is the exact mirror — it implements the first and refuses
//            the second, and wakes in ~0.3s.
//          • Once awake it stays awake for that process's lifetime.
//
//        That mirror is the whole argument for sending BOTH and trusting
//        NEITHER return code. The settle poll is the only verdict true for both.
//
//        THE SIDE EFFECT, AND WHY IT IS BOUNDED. `AXEnhancedUserInterface` is
//        the flag that makes some AppKit apps re-lay-out their windows. Chrome
//        reports it unimplemented, so nothing is applied — and nothing reaches
//        this file without positive web-host evidence from `WebContentHost`,
//        whose last rung is `.none` rather than "try anyway".
//

import ApplicationServices
import Foundation
import os

enum WebAXWakeup {

    static let manualAccessibilityAttribute = "AXManualAccessibility"
    /// The signal Chrome actually wakes on. See the header: the set reports
    /// notImplemented and the tree arrives regardless.
    static let enhancedInterfaceAttribute = "AXEnhancedUserInterface"

    /// How often the settle poll asks. A quarter second against a 2.3s wake is
    /// nine chances to notice and costs one bounded walk each.
    static let pollInterval: Duration = .milliseconds(250)

    /// The pure gate, so "who gets woken" has exactly one definition. WebKit's
    /// tree is already up and `.none` has no evidence it should be poked —
    /// both are `notNeeded`, for opposite reasons.
    static func needsWake(_ kind: WebContentHost.Kind) -> Bool {
        switch kind {
        case .chromium, .electron: return true
        case .webkit, .none: return false
        }
    }

    /// Pids already woken this session. A memo, not a guarantee — a browser may
    /// relaunch into the same pid — and re-sending is a cheap no-op, so it is
    /// only ever read to skip the SETTLE, never to claim readiness.
    private static let woken = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])

    static func ensure(pid: pid_t, timeout: TimeInterval) async -> BrowserAXReadiness.Readiness {
        let application = AXUIElementCreateApplication(pid)
        if WebAreaLocator.firstWebArea(inApp: application) != nil {
            woken.withLock { _ = $0.insert(pid) }
            return .ready
        }
        // BOTH SIGNALS, RESULT CODES DELIBERATELY DISCARDED. Between them the
        // two hosts implement one attribute each and disagree about which.
        AXUIElementSetAttributeValue(
            application, manualAccessibilityAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            application, enhancedInterfaceAttribute as CFString, kCFBooleanTrue)
        woken.withLock { _ = $0.insert(pid) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return .axTreeAbsent }
            if WebAreaLocator.firstWebArea(inApp: application) != nil { return .ready }
            do { try await Task.sleep(for: pollInterval) } catch { return .axTreeAbsent }
        }
        return WebAreaLocator.firstWebArea(inApp: application) != nil ? .ready : .axTreeAbsent
    }
}

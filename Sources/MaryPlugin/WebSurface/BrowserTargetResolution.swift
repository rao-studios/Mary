//
//  BrowserTargetResolution.swift
//  MaryPlugin
//
//  WHAT: Which browser a turn is about, as a pure ladder.
//  IN:   WebSurfaceSupport (every rung injected)
//  OUT:  a bundle identifier, or nil
//  PIN:  AMBIGUITY ANSWERS NIL. Two browsers with windows on screen and no evidence
//        either way is a question, not a coin flip — acting on the wrong one navigates
//        somebody's other window away from what they were reading.
//        NAMED BEATS EVIDENCE, ALWAYS. If the person said "in Safari", no ledger
//        outranks that; the rungs below only answer when they did not say.
//        Ported from the reference port's own ladder, kept pure so every rung is
//        testable without a workspace.
//

import AppKit
import CoreGraphics
import Foundation

public enum BrowserTargetResolution {

    /// The ladder. Every input is data, so the whole thing is one testable function.
    public static func bundleID(
        named: String?,
        frontmost: String?,
        freshEvidence: String?,
        recentEvidence: String?,
        onScreen: [String],
        running: [String],
        isBrowser: (String) -> Bool
    ) -> String? {
        func admitted(_ candidate: String?) -> String? {
            guard let candidate, isBrowser(candidate),
                  running.contains(where: { $0 == candidate })
            else { return nil }
            return candidate
        }

        if let named = admitted(named) { return named }
        if let frontmost = admitted(frontmost) { return frontmost }
        if let fresh = admitted(freshEvidence) { return fresh }
        if let recent = admitted(recentEvidence) { return recent }

        // WHICH BROWSER CAN THEY ACTUALLY SEE. One is an answer; two is a question.
        let visible = Array(Set(onScreen.filter { isBrowser($0) && running.contains($0) }))
        if visible.count == 1 { return visible[0] }
        if visible.count > 1 { return nil }

        let alive = Array(Set(running.filter(isBrowser)))
        return alive.count == 1 ? alive[0] : nil
    }

    /// Bundle identifiers of processes with a window on screen right now.
    ///
    /// The window list, not screen capture: this answers "can they see it" and needs no
    /// Screen Recording grant to do so.
    public static func onScreenBundleIDs() -> [String] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        let pids = Set(windows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        return pids.compactMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
    }
}

//
//  AppAutomationGate.swift
//  MaryBrain
//
//  The shared preflight for anything that drives another app's UI —
//  System Events menu clicks (Scrivener ceremonies) and synthetic keyboard
//  events (the typer). Two facts make these gates load-bearing:
//  1. Without Accessibility, a System Events `click` on a menu item returns
//     "OK" while doing NOTHING, and CGEvent posts are silently swallowed —
//     the honest refusal here is the only thing standing between the user
//     and a fake success.
//  2. Synthetic key events land in whatever app is FRONTMOST at post time,
//     so callers must verify the intended target holds focus — before and,
//     for long operations, between every chunk.
//

import AppKit
import ApplicationServices
import Foundation

public enum AppAutomationGate {

    /// Nil when this process is AX-trusted; otherwise the spoken ask.
    /// Uses the same signal as PermissionsCenter (AXIsProcessTrusted).
    public static func accessibilityBlock() -> String? {
        AXIsProcessTrusted() ? nil : accessibilityMessage
    }

    public static let accessibilityMessage =
        "Typing into apps needs Accessibility access — open my Settings, and under Permissions grant Accessibility."

    /// Whether the frontmost app matches a bundle-id PREFIX (Scrivener's
    /// variants share one; an exact id is just a full-length prefix).
    public static func frontmostHasPrefix(_ bundleIDPrefix: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier?
            .hasPrefix(bundleIDPrefix) == true
    }

    // ACTIVATION IS NOT THIS LAYER'S JOB, and `waitUntilFrontmost` used to be
    // here. It was a third copy of the single-road activation the tree has
    // twice been burned by: a bare `.activate()` with no unhide, no
    // `.activateAllWindows`, no Apple Events retry, and a background poll of
    // `NSWorkspace.frontmostApplication` that can stay stale for the whole
    // deadline and report a landed raise as a failure.
    //
    // It cannot simply call the fixed version: `VerifiedActivation` lives in
    // MaryAdapter, which depends on THIS package, and this package's
    // standing rule is that it knows nothing about plugins or any specific
    // application. So the verb moved up to its callers, every one of which
    // already sits above the kit. What stays here is the permission question
    // and the frontmost predicate — facts, not ceremonies.
}

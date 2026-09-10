//
//  AppAutomationGate.swift
//  MaryBrain
//
//  WHAT: Shared preflight for driving another app's UI (System Events, typer).
//  OUT:  accessibilityBlock / frontmostHasPrefix. Activation: VerifiedActivation (MaryAdapter).
//  PIN:  Without AX, a System Events click returns "OK" while doing nothing.
//        Synthetic keys land in whatever is frontmost at post time.
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

    // ACTIVATION IS NOT THIS LAYER'S JOB.
}

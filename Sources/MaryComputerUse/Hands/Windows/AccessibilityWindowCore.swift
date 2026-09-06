//
//  AccessibilityWindowCore.swift
//  MaryComputerUse
//
//  WHAT: Raise primitives — raise, full screen, restore, bring forward.
//  IN:   AccessibilityWindowManagementAdapter (MaryPlugin)
//  OUT:  AXWindowRoster.axWindows for the read; AX actions for the acts
//  PIN:  Hands/Windows, not tree machinery. Every write is CHECKED — that is
//        the whole reason this core exists. The window LIST is a tier-0 read
//        and lives in Accessibility/AXWindowRoster.
//

import AppKit
import ApplicationServices
import Foundation

public enum AccessibilityWindowCore {

    public typealias AXWindow = AXWindowRoster.AXWindow

    /// Every AX window of the process, front-to-back, standard windows only
    /// when `standardOnly`. The read is `AXWindowRoster.axWindows`; this
    /// forwarder is where a miss becomes a sentence a person can act on.
    public static func axWindows(
        of pid: pid_t, standardOnly: Bool = false
    ) throws -> [AXWindow] {
        guard AXIsProcessTrusted() else {
            ComputerUseMonitor.shared.note(lane: .windows, refused: "axWindows", pid: pid,
                    reason: .accessibilityUntrusted)
            throw WindowManagementError.accessibilityRequired
        }
        guard let windows = AXWindowRoster.axWindows(of: pid, standardOnly: standardOnly)
        else {
            ComputerUseMonitor.shared.note(
                lane: .windows, refused: "axWindows", pid: pid,
                reason: .other("the process did not answer with a window list"))
            throw WindowManagementError.operationFailed(
                "Accessibility couldn't enumerate that application's windows.")
        }
        return windows
    }

    /// Raise with a CHECKED return — the whole reason this core exists.
    public static func raise(_ element: AXUIElement, title: String) throws {
        guard AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success else {
            ComputerUseMonitor.shared.note(
                lane: .windows, refused: "raise",
                reason: .pressRefused(title.isEmpty ? "that window" : title))
            throw WindowManagementError.operationFailed(
                "I couldn't raise \(title.isEmpty ? "that window" : title).")
        }
        ComputerUseMonitor.shared.note(lane: .windows, act: "raise", detail: title)
    }

    /// A STRING LITERAL BECAUSE APPLE NEVER EXPORTED THE CONSTANT.
    public static let fullScreenAttribute = "AXFullScreen"

    /// Enter or leave full screen, with a CHECKED write and a CHECKED read.
    public static func setFullScreen(
        _ element: AXUIElement, enabled: Bool, title: String
    ) throws {
        let name = title.isEmpty ? "that window" : title
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
                element, fullScreenAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            throw WindowManagementError.operationFailed(
                "\(name) doesn't have a full-screen mode I can switch.")
        }
        if copyBool(element, fullScreenAttribute) == enabled { return }
        guard AXUIElementSetAttributeValue(
            element, fullScreenAttribute as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse) == .success
        else {
            ComputerUseMonitor.shared.note(lane: .windows, refused: "setFullScreen", reason: .pressRefused(name))
            throw WindowManagementError.operationFailed(
                enabled
                    ? "\(name) refused to go full screen."
                    : "\(name) refused to leave full screen.")
        }
        ComputerUseMonitor.shared.note(
            lane: .windows, act: "setFullScreen",
            detail: "\(name) \(enabled ? "on" : "off")")
    }

    /// Un-minimize when needed; a no-op on a visible window.
    public static func restore(_ element: AXUIElement) throws {
        guard let minimized = copyBool(element, kAXMinimizedAttribute) else {
            throw WindowManagementError.operationFailed(
                "Accessibility couldn't determine whether that window is minimized.")
        }
        guard minimized else { return }
        guard AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        else {
            ComputerUseMonitor.shared.note(
                lane: .windows, refused: "restore",
                reason: .other("the window refused to un-minimize"))
            throw WindowManagementError.operationFailed(
                "Accessibility couldn't restore that minimized window.")
        }
        ComputerUseMonitor.shared.note(lane: .windows, act: "restore")
    }

    /// Minimize with a CHECKED write; a no-op on a window already minimized.
    /// The counterpart of `restore`, so a runner can stage the state the
    /// activation ladder's raise road exists for.
    public static func minimize(_ element: AXUIElement) throws {
        if copyBool(element, kAXMinimizedAttribute) == true { return }
        guard AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        else {
            ComputerUseMonitor.shared.note(
                lane: .windows, refused: "minimize",
                reason: .other("the window refused to minimize"))
            throw WindowManagementError.operationFailed(
                "Accessibility couldn't minimize that window.")
        }
        ComputerUseMonitor.shared.note(lane: .windows, act: "minimize")
    }

    /// Activate and WAIT until the process is actually frontmost.
    public static func activate(pid: pid_t) async -> Bool {
        // The two roads now live in `VerifiedActivation`, at the contract root — extracted
        // verbatim so `open_app` and the typer's pre-keystroke gate share this.
        await VerifiedActivation.bringForward(pid: pid).succeeded
    }

    // `isFrontmost` and `frontmost(pid:within:)` lived here and were the originals —
    // main-actor reads, written because "TextEdit didn't come to the foreground" was.

    public static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        AXWindowRoster.copyString(element, attribute)
    }

    public static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        AXWindowRoster.copyBool(element, attribute)
    }
}

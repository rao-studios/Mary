//
//  AccessibilityWindowCore.swift
//  MaryAdapter
//
//  WHAT: Raise primitives (AX window list, raise, front).
//  IN:   AccessibilityWindowManagementAdapter | TextEditWindowManagementAdapter
//  OUT:  AXWindowRoster
//  PIN:  Sibling of Adapters/WindowManagement — not tree machinery.

import AppKit
import ApplicationServices
import Foundation

enum AccessibilityWindowCore {

    struct AXWindow {
        var title: String
        var element: AXUIElement
        var minimized: Bool?
        var subrole: String?
    }

    /// Every AX window of the process, front-to-back, standard windows only
    /// when `standardOnly` — panels (Open, Find) never appear in a document
    /// roster and pairing against them would shift every rank.
    static func axWindows(
        of pid: pid_t, standardOnly: Bool = false
    ) throws -> [AXWindow] {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityRequired }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &raw) == .success,
            let elements = raw as? [AXUIElement]
        else {
            throw WindowManagementError.operationFailed(
                "Accessibility couldn't enumerate that application's windows.")
        }
        let windows = elements.map { element in
            AXUIElementSetMessagingTimeout(element, 0.25)
            return AXWindow(
                title: copyString(element, kAXTitleAttribute) ?? "",
                element: element,
                minimized: copyBool(element, kAXMinimizedAttribute),
                subrole: copyString(element, kAXSubroleAttribute))
        }
        guard standardOnly else { return windows }
        return windows.filter { $0.subrole == kAXStandardWindowSubrole as String }
    }

    /// Raise with a CHECKED return — the whole reason this core exists.
    static func raise(_ element: AXUIElement, title: String) throws {
        guard AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success else {
            throw WindowManagementError.operationFailed(
                "I couldn't raise \(title.isEmpty ? "that window" : title).")
        }
    }

    /// A STRING LITERAL BECAUSE APPLE NEVER EXPORTED THE CONSTANT.
    static let fullScreenAttribute = "AXFullScreen"

    /// Enter or leave full screen, with a CHECKED write and a CHECKED read.
    static func setFullScreen(
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
            throw WindowManagementError.operationFailed(
                enabled
                    ? "\(name) refused to go full screen."
                    : "\(name) refused to leave full screen.")
        }
    }

    /// Un-minimize when needed; a no-op on a visible window.
    static func restore(_ element: AXUIElement) throws {
        guard let minimized = copyBool(element, kAXMinimizedAttribute) else {
            throw WindowManagementError.operationFailed(
                "Accessibility couldn't determine whether that window is minimized.")
        }
        guard minimized else { return }
        guard AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        else {
            throw WindowManagementError.operationFailed(
                "Accessibility couldn't restore that minimized window.")
        }
    }

    /// Activate and WAIT until the process is actually frontmost.
    static func activate(pid: pid_t) async -> Bool {
        // The two roads now live in `VerifiedActivation`, at the contract root — extracted
        // verbatim so `open_app` and the typer's pre-keystroke gate share this.
        await VerifiedActivation.bringForward(pid: pid).succeeded
    }

    // `isFrontmost` and `frontmost(pid:within:)` lived here and were the originals —
    // main-actor reads, written because "TextEdit didn't come to the foreground" was.

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        AX.string(element, attribute)
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        AX.attribute(element, attribute) as? Bool
    }
}

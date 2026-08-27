//
//  AccessibilityWindowCore.swift
//  MaryAdapter
//
//  Split out of Adapters/WindowManagement/AccessibilityWindowManagementAdapter.swift
//  (AXEngine consolidation) — pure relocation, no declaration changed. The
//  `AccessibilityWindowManagementAdapter` struct that used to sit beside this
//  enum stayed in Adapters/ (it is a WindowManagementAdapter, not tree
//  machinery); TextEditWindowManagementAdapter also calls this enum by its
//  bare name, unaffected by the move — both are the same MaryAdapter target.
//
//  THE RAISE PRIMITIVES, EXTRACTED so the TextEdit specialist can borrow them.
//
//  TextEdit's own dictionary is better than AX at NAMING windows — stable
//  `window id`s that survive reordering, a roster that filters ghosts, a
//  conversation resolver — but its `set index of w to 1` write reorders the
//  scriptable window list without reliably raising anything on screen, and it
//  returns no error when it does nothing. `kAXRaiseAction` is the primitive
//  with a checked return code, and this core is the one place it lives:
//  activation-with-verification, restore, raise, and the window enumeration
//  they need. The generic adapter delegates here unchanged; the TextEdit
//  adapter pairs its script-named windows onto these elements by title.
//

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

    /// A STRING LITERAL BECAUSE APPLE NEVER EXPORTED THE CONSTANT. The
    /// attribute has been public and documented since Lion, but there is no
    /// `kAXFullscreenAttribute` in the Swift overlay (nor in the C headers) —
    /// AppKit's own full-screen support went in through `NSWindow`, and the
    /// AX name was left as a bare string. Spelled once, here, rather than at
    /// each of its three uses.
    static let fullScreenAttribute = "AXFullScreen"

    /// Enter or leave full screen, with a CHECKED write and a CHECKED read.
    ///
    /// `AXFullScreen` IS THE HONEST PRIMITIVE, and the alternative is worth
    /// naming: Control-Command-F is a keystroke into whatever is frontmost,
    /// it is remappable, and it reports nothing. This is a settable window
    /// attribute — one write, one verification, one true sentence about what
    /// happened. It also composes with the rest of this file rather than
    /// needing the stage.
    ///
    /// A window that does not expose the attribute REFUSES rather than
    /// silently doing nothing: many panels and some older applications have
    /// no full-screen mode at all, and "I made it full screen" about a window
    /// that did not move is the class of lie this whole adapter exists to
    /// avoid.
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

    /// Activate and WAIT until the process is actually frontmost. macOS 14's
    /// cooperative activation can refuse silently; an unverified activate
    /// followed by raises is how "Brought all N windows forward" reported
    /// success while everything stayed behind the user's browser.
    ///
    /// TWO ROADS, VERIFIED ONCE EACH. `NSRunningApplication.activate` is
    /// cooperative and a non-frontmost caller (a probe, a background Mary)
    /// can be refused outright — observed live: the refusal was honest, and
    /// then the activation landed AFTER the deadline anyway. The Apple Events
    /// `activate` verb takes the other door (the target activates itself),
    /// so a missed first deadline retries through it before giving up.
    static func activate(pid: pid_t) async -> Bool {
        // The two roads now live in `VerifiedActivation`, at the contract root —
        // extracted verbatim so `open_app` and the typer's pre-keystroke gate
        // share this adapter's proven pattern instead of running their own
        // single-road activations. Behavior identical; one implementation.
        await VerifiedActivation.bringForward(pid: pid).succeeded
    }

    // THE FRONTMOST VERIFICATION LEFT WITH THE ACTIVATION IT SERVED.
    //
    // `isFrontmost` and `frontmost(pid:within:)` lived here and were the
    // originals — main-actor reads, written because "TextEdit didn't come to
    // the foreground" was a VERIFICATION failure, not an activation one, and a
    // background poll of `NSWorkspace.frontmostApplication` can stay stale for
    // a whole deadline. `VerifiedActivation` now owns both roads and both
    // reads; keeping a second copy here meant the fix could be improved in one
    // place and left behind in the other, which is precisely how the original
    // incident shipped twice.

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        AX.string(element, attribute)
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        AX.attribute(element, attribute) as? Bool
    }
}

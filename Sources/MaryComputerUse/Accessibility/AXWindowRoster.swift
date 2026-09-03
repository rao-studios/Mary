//
//  AXWindowRoster.swift
//  MaryComputerUse
//
//  WHAT: The process's AX window list, and the roster the builder walks.
//  IN:   AXUIElementCopyAttributeValue(kAXWindows)
//  OUT:  AXSnapshotBuilder | Hands/Windows/AccessibilityWindowCore
//  PIN:  The READ lives here, in tier 0; the ACTS on these windows live in
//        Hands/Windows. Failures become an empty roster — a render loop must
//        not abort — and the acting side turns nil into its own sentence.
//

import ApplicationServices
import Foundation

public enum AXWindowRoster {

    /// One AX window, as the tree reports it. Carries the live element because
    /// both the snapshot walk and the raise primitives need to address it.
    public struct AXWindow {
        public var title: String
        public var element: AXUIElement
        public var minimized: Bool?
        public var subrole: String?
    }

    struct Entry {
        var element: AXUIElement
        var title: String
        var frame: CGRect?
        var isMain: Bool
        var isMinimized: Bool
    }

    /// Every AX window of the process, front-to-back, standard windows only
    /// when `standardOnly` — panels (Open, Find) never appear in a document
    /// roster and pairing against them would shift every rank.
    ///
    /// PIN: nil is "the process declined to answer", which the caller words.
    /// This function makes no claim about the Accessibility grant; ask
    /// `AXIsProcessTrusted()` where a person will read the answer.
    public static func axWindows(
        of pid: pid_t, standardOnly: Bool = false
    ) -> [AXWindow]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &raw) == .success,
            let elements = raw as? [AXUIElement]
        else { return nil }
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

    /// Front-to-back, standard windows only by default (panels excluded —
    /// same convention as `axWindows`). Empty when AX is untrusted or the
    /// process declines to answer; never throws.
    static func windows(pid: pid_t, standardOnly: Bool = true) -> [Entry] {
        guard let axWindows = axWindows(of: pid, standardOnly: standardOnly)
        else { return [] }
        return axWindows.map { window in
            Entry(
                element: window.element,
                title: window.title,
                frame: AX.frame(of: window.element),
                isMain: AX.attribute(window.element, kAXMainAttribute) as? Bool ?? false,
                isMinimized: window.minimized ?? false)
        }
    }

    public static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        AX.string(element, attribute)
    }

    public static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        AX.attribute(element, attribute) as? Bool
    }
}

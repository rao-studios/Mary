//
//  AXWindowIdentity.swift
//  MaryComputerUse
//
//  WHAT: The one identity a window keeps: its CGWindowID, asked of its
//        accessibility element.
//  PIN:  A WINDOW IS NOT "THE MAIN ONE". Chrome's main window is whichever the
//        person last clicked, and a lane that read, pressed and raised "the main
//        window" worked in the person's own window the moment they touched it —
//        measured in round 9: trips opened tabs and played a video in a window
//        somebody was reading in. The window Mary works in is a window she
//        identifies, and keeps identifying.
//

import ApplicationServices
import CoreGraphics
import Foundation
import MaryAmbient

public enum AXWindowIdentity {

    /// The window-server id behind an accessibility window element.
    public static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The application's window with this id, if it is still there.
    public static func window(id: CGWindowID, in pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        return AX.children(application, kAXWindowsAttribute as String)
            .first { windowID(of: $0) == id }
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

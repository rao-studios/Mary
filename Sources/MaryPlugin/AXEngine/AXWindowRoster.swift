//
//  AXWindowRoster.swift
//  MaryAdapter
//
//  WHAT: Best-effort window list for the snapshot builder.
//  IN:   AccessibilityWindowCore.axWindows  OUT: AXSnapshotBuilder
//  PIN:  Throws become empty roster — a render loop must not abort.

import ApplicationServices
import Foundation

enum AXWindowRoster {

    struct Entry {
        var element: AXUIElement
        var title: String
        var frame: CGRect?
        var isMain: Bool
        var isMinimized: Bool
    }

    /// Front-to-back, standard windows only by default (panels excluded —
    /// same convention as `AccessibilityWindowCore.axWindows`). Empty when
    /// AX is untrusted or the process declines to answer; never throws.
    static func windows(pid: pid_t, standardOnly: Bool = true) -> [Entry] {
        guard let axWindows = try? AccessibilityWindowCore.axWindows(
            of: pid, standardOnly: standardOnly)
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
}

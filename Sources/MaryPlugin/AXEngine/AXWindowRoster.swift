//
//  AXWindowRoster.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  A non-throwing, best-effort wrapper over `AccessibilityWindowCore.axWindows`
//  for the builder's use. `AccessibilityWindowCore` throws — the right
//  contract for an action that reports failure to a user ("I couldn't raise
//  that window") — but a snapshot builder's honest answer to "AX declined"
//  is an empty roster plus a trust check, not a thrown error interrupting a
//  render loop.
//

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

//
//  CodeSurfaceEditorCache.swift
//  MaryPlugin
//
//  WHAT: One expensive locate per window, shared by code and prose polls.
//  IN:   DeclaredTextAX  OUT: Observer / Adapter Skills
//  PIN:  Write policy is not this file.

import AppKit
import ApplicationServices
import Foundation
import MaryComputerUse
import os

public enum CodeSurfaceEditorCache {

    private struct Entry {
        var pid: pid_t
        var window: AXUIElement
        var editor: AXUIElement
        var role: String
    }

    private static let box = OSAllocatedUnfairLock<Entry?>(initialState: nil)
    private static let walkCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)

    public static var walkCount: Int { walkCountBox.withLock { $0 } }

    public static func resetWalkCount() { walkCountBox.withLock { $0 = 0 } }

    public static func editor<R: DeclaredTextSurface>(
        pid: pid_t,
        window: AXUIElement,
        registration: R,
        locate: (AXUIElement, R) -> AXUIElement? = { DeclaredTextAX.editor(in: $0, registration: $1) },
        role: (AXUIElement) -> String? = { AX.string($0, kAXRoleAttribute) },
        focused: (AXUIElement) -> Bool = { DeclaredTextAX.isFocused($0) }
    ) -> AXUIElement? {
        if let cached = box.withLock({ $0 }),
           cached.pid == pid,
           CFEqual(cached.window, window),
           let live = role(cached.editor),
           live == cached.role,
           registration.editorRoleNames.contains(live),
           !registration.preferFocusedElement || focused(cached.editor) {
            return cached.editor
        }
        walkCountBox.withLock { $0 += 1 }
        guard let editor = locate(window, registration),
              let role = role(editor)
        else {
            box.withLock { $0 = nil }
            return nil
        }
        box.withLock { $0 = Entry(pid: pid, window: window, editor: editor, role: role) }
        return editor
    }

    public static func frontSurface<R: DeclaredTextSurface>(
        pid: pid_t,
        registration: R,
        focusedWindow: (AXUIElement) -> AXUIElement? =
            { AX.element($0, kAXFocusedWindowAttribute) },
        locate: (AXUIElement, R) -> AXUIElement? =
            { DeclaredTextAX.editor(in: $0, registration: $1) },
        role: (AXUIElement) -> String? = { AX.string($0, kAXRoleAttribute) },
        focused: (AXUIElement) -> Bool = { DeclaredTextAX.isFocused($0) },
        locateAll: (pid_t, R) -> DeclaredTextAX.Surface? =
            { DeclaredTextAX.frontSurface(pid: $0, registration: $1) }
    ) -> DeclaredTextAX.Surface? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, DeclaredTextAX.messagingTimeout)
        guard let window = focusedWindow(application),
              let editor = editor(
                pid: pid, window: window, registration: registration,
                locate: locate, role: role, focused: focused)
        else { return locateAll(pid, registration) }

        return DeclaredTextAX.Surface(
            window: window,
            editor: editor,
            documentKey: DeclaredTextAX.documentKey(
                of: window, registration: registration, ordinal: 1),
            title: AX.string(window, kAXTitleAttribute) ?? "",
            ordinal: 1)
    }

    public static func invalidate() {
        box.withLock { $0 = nil }
    }

    public static var isPrimed: Bool { box.withLock { $0 != nil } }
}

//
//  AccessibilityWindowManagementAdapter.swift
//  MaryBrain
//
//  The generic macOS binding. It deliberately stops at public Accessibility
//  APIs: no private window-number bridge, no screen capture, and no menu click
//  that can report success while doing nothing.
//
//  `AccessibilityWindowCore` — the raise/restore/enumerate primitives this
//  adapter delegates to — moved to `AXEngine/AccessibilityWindowCore.swift`
//  (AXEngine consolidation); same target, same bare name, nothing here
//  changed but the import list.
//

import AppKit
import ApplicationServices
import Foundation

struct AccessibilityWindowManagementAdapter: WindowManagementAdapter {
    let id = "macos-accessibility"

    func supports(application: ManagedApplication) -> Bool { true }

    func windows(in application: ManagedApplication) async throws -> [ManagedWindow] {
        try entries(in: application).map(\.window)
    }

    func restore(_ window: ManagedWindow, in application: ManagedApplication) async throws {
        let entry = try entry(for: window.id, in: application)
        try AccessibilityWindowCore.restore(entry.element)
    }

    func raise(_ window: ManagedWindow, in application: ManagedApplication) async throws {
        guard await AccessibilityWindowCore.activate(pid: application.processIdentifier) else {
            throw WindowManagementError.operationFailed(
                "\(application.displayName) didn't come to the foreground.")
        }
        let entry = try entry(for: window.id, in: application)
        try AccessibilityWindowCore.restore(entry.element)
        try AccessibilityWindowCore.raise(entry.element, title: window.title)
    }

    func setFullScreen(
        _ window: ManagedWindow, in application: ManagedApplication, enabled: Bool
    ) async throws {
        // ENTERING FULL SCREEN MOVES A WINDOW TO ITS OWN SPACE, so it has to
        // be the window in front first — otherwise the user is left looking
        // at a Space that does not hold what they asked about.
        guard await AccessibilityWindowCore.activate(pid: application.processIdentifier) else {
            throw WindowManagementError.operationFailed(
                "\(application.displayName) didn't come to the foreground.")
        }
        let entry = try entry(for: window.id, in: application)
        try AccessibilityWindowCore.restore(entry.element)
        try AccessibilityWindowCore.raise(entry.element, title: window.title)
        try AccessibilityWindowCore.setFullScreen(
            entry.element, enabled: enabled, title: window.title)
    }

    func raiseAll(
        _ windows: [ManagedWindow], in application: ManagedApplication
    ) async throws -> Int {
        guard await AccessibilityWindowCore.activate(pid: application.processIdentifier) else {
            throw WindowManagementError.operationFailed(
                "\(application.displayName) didn't come to the foreground.")
        }

        let current = try entries(in: application)
        var byID: [String: AXUIElement] = [:]
        for entry in current { byID[entry.window.id] = entry.element }
        var raised = 0
        // AXWindows is front-to-back. Raise back-to-front so the user's
        // existing order survives and the original front window is raised last.
        for window in windows.sorted(by: { $0.index > $1.index }) {
            guard let element = byID[window.id] else {
                throw WindowManagementError.operationFailed(
                    "One \(application.displayName) window closed before it could be raised.")
            }
            try AccessibilityWindowCore.restore(element)
            do {
                try AccessibilityWindowCore.raise(element, title: window.title)
            } catch {
                throw WindowManagementError.operationFailed(
                    "I raised \(raised) of \(windows.count) \(application.displayName) windows; one refused the Accessibility raise action.")
            }
            raised += 1
        }
        return raised
    }

    private struct Entry {
        var window: ManagedWindow
        var element: AXUIElement
    }

    private func entries(in application: ManagedApplication) throws -> [Entry] {
        let windows = try AccessibilityWindowCore.axWindows(
            of: application.processIdentifier)
        return windows.enumerated().map { offset, axWindow in
            let nativeIdentifier = AccessibilityWindowCore
                .copyString(axWindow.element, kAXIdentifierAttribute)
                .flatMap { $0.isEmpty ? nil : $0 }
            // AX has no universal public window-number attribute. CFHash is
            // the server-side AX object's stable identity for its lifetime;
            // prefixing pid prevents identity from crossing an app relaunch.
            let hash = String(CFHash(axWindow.element))
            let localIdentity = nativeIdentifier.map { "\($0):\(hash)" } ?? hash
            let identity = "\(application.processIdentifier):\(localIdentity)"
            return Entry(
                window: ManagedWindow(
                    id: identity,
                    title: axWindow.title,
                    index: offset + 1,
                    isMinimized: axWindow.minimized),
                element: axWindow.element)
        }
    }

    private func entry(for id: String, in application: ManagedApplication) throws -> Entry {
        guard let entry = try entries(in: application).first(where: { $0.window.id == id }) else {
            throw WindowManagementError.windowNotFound(id)
        }
        return entry
    }
}

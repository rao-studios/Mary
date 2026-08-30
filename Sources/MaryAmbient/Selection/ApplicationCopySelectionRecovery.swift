//
//  ApplicationCopySelectionRecovery.swift
//  MaryAmbient
//
//  WHAT: Machine-level payload recovery when AX cannot return selected characters.
//  IN:   SelectionHandoffCoordinator.swift (split)
//  PIN:  Not a clipboard skill. Adapters opt in and verify source lifecycle before and after.
//

import AppKit
import Foundation
import os

/// A machine-level payload recovery mechanism for editor adapters whose Accessibility
/// surface cannot reliably return its selected characters.
public enum ApplicationCopySelectionRecovery {
    private static let gestureSuppressionBox = OSAllocatedUnfairLock<Date>(
        initialState: .distantPast)

    /// Native menu activation can itself emit a synthetic mouse-up. Hold the
    /// gesture sampler through the operation and a short delivery tail so
    /// Mary never interprets its own Copy as a new user interaction.
    public static func suppressesSelectionGesture(at date: Date = Date()) -> Bool {
        gestureSuppressionBox.withLock { date < $0 }
    }

    /// Ask one lifecycle-verified source process to materialize its current selection through
    /// Copy, preserving every pasteboard flavor.
    @MainActor
    public static func read(from pid: pid_t, timeout: TimeInterval) async -> String? {
        gestureSuppressionBox.withLock { $0 = .distantFuture }
        defer {
            gestureSuppressionBox.withLock {
                $0 = Date().addingTimeInterval(0.75)
            }
        }
        let diagnostics = ProcessInfo.processInfo.environment[
            "MARY_LIVE_SELECTION_COPY_PROBE"] == "1"
        if diagnostics {
            let source = NSRunningApplication(processIdentifier: pid)
            print("[selection-copy] begin pid=\(pid) active=\(source?.isActive == true) "
                + "front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        }
        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] =
            (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        defer {
            pasteboard.clearContents()
            if !savedItems.isEmpty {
                let restored = savedItems.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(restored)
            }
        }

        let initialChange = pasteboard.changeCount
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(
                keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return nil }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        let sourceIsActive = NSRunningApplication(processIdentifier: pid)?.isActive == true
        var nativeCopyIssued = false
        if sourceIsActive {
            switch performNativeCopy(pid: pid) {
            case .issued:
                nativeCopyIssued = true
            case .disabled:
                // The application itself says there is NOTHING TO COPY. Pressing the disabled item — or
                // falling through to a Cmd-C the app will reject the same way — is the system beep the
                // user hears on an unrelated turn.
                if diagnostics { print("[selection-copy] copy menu disabled — standing down") }
                return nil
            case .notFound:
                break
            }
        }
        if diagnostics {
            print("[selection-copy] native-menu-issued=\(nativeCopyIssued)")
        }
        if !nativeCopyIssued {
            // Cmd-C only into the FRONTMOST source. A copy keystroke posted to a background
            // application is exactly the invalid-action beep — audible on whatever turn happens to be
            // running — and its capture was best-effort to begin with.
            guard sourceIsActive else {
                if diagnostics { print("[selection-copy] source not frontmost — standing down") }
                return nil
            }
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, pasteboard.changeCount == initialChange {
            try? await Task.sleep(for: .milliseconds(20))
        }

        guard pasteboard.changeCount != initialChange,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty
        else {
            if diagnostics { print("[selection-copy] no clipboard transaction") }
            return nil
        }
        if diagnostics { print("[selection-copy] captured \(text.count) characters") }
        return text
    }

    /// What the native-menu Copy attempt concluded — three answers, because
    /// "found but DISABLED" is positive evidence there is nothing to copy and
    /// must stop the whole capture, while "not found" merely falls back.
    private enum NativeCopyOutcome {
        case issued
        case disabled
        case notFound
    }

    /// Invoke the source application's standard Command-C menu item. The
    /// command character plus zero extra modifiers keeps this locale-neutral
    /// while excluding commands such as Copy Style (Option-Command-C).
    private static func performNativeCopy(pid: pid_t) -> NativeCopyOutcome {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let rawMenuBar = AX.element(application, kAXMenuBarAttribute)
        else { return .notFound }

        var queue: [(AXUIElement, Int)] = [(rawMenuBar, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = AX.string(element, kAXRoleAttribute)
            if role == kAXMenuItemRole as String {
                let title = AX.string(element, kAXTitleAttribute)
                let command = AX.string(element, kAXMenuItemCmdCharAttribute)
                let modifiers = AX.number(
                    element, kAXMenuItemCmdModifiersAttribute)?.intValue
                if title == "Copy"
                    || (command?.lowercased() == "c" && (modifiers ?? 0) == 0)
                {
                    // A DISABLED Copy item pressed anyway is the macOS funk
                    // beep — and it presses on every turn boundary while a
                    // stale lease points here. Check before acting.
                    if let enabled = AX.attribute(element, kAXEnabledAttribute) as? Bool,
                       !enabled {
                        return .disabled
                    }
                    return AXUIElementPerformAction(
                        element, kAXPressAction as CFString) == .success
                        ? .issued : .notFound
                }
            }
            guard depth < 5 else { continue }
            queue.append(contentsOf: AX.children(element).map { ($0, depth + 1) })
        }
        return .notFound
    }
}

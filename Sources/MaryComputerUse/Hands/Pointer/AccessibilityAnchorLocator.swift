//
//  AccessibilityAnchorLocator.swift
//  MaryComputerUse
//
//  WHAT: Find ONE element a closed locator describes, and the focused window.
//  IN:   PluginAccessibilityAnchorLocatorSchema (package-declared, closed)
//  OUT:  a frame the pointer lane can aim at
//  PIN:  EXACTLY ONE MATCH OR NOTHING. Two matches is not "pick the first" —
//        it means the locator does not identify a control, and aiming at a
//        guess clicks something the user never named. The search is bounded
//        because a parent chain is another process's data structure.
//

import ApplicationServices
import CoreGraphics
import Foundation

public enum AccessibilityAnchorLocator {

    /// A focused window, carried opaquely. Callers compare identity and read a
    /// frame; nobody above this target names `AXUIElement`.
    ///
    /// PIN: `@unchecked Sendable` — an `AXUIElement` is a CF type this package
    /// already hands between tasks; equality is `CFEqual`, which is the honest
    /// identity test for "is this still the same window".
    public struct FocusedWindow: @unchecked Sendable, Equatable {
        let element: AXUIElement

        public static func == (lhs: FocusedWindow, rhs: FocusedWindow) -> Bool {
            CFEqual(lhs.element, rhs.element)
        }

        public var frame: CGRect? { AX.frame(of: element) }
    }

    public enum Failure: Error, Equatable, Sendable {
        case noFocusedWindow
        /// Zero matches, or more than one. Both mean the same thing to a user.
        case anchorNotUnique
        case anchorHasNoFrame
    }

    /// How far the search may go before it gives up. Named because a malformed
    /// tree is a hang wearing another application's bug.
    public static let containerBudget = 400
    public static let descendantBudget = 200

    // MARK: - The focused window

    public static func focusedWindow(pid: pid_t) -> FocusedWindow? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let window = value, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return FocusedWindow(element: (window as! AXUIElement))
    }

    // MARK: - The anchor

    /// The frame of the single element this locator names, under the focused
    /// window. A frame narrower or shorter than a point is treated as no
    /// frame — it cannot be aimed at.
    public static func anchorFrame(
        _ locator: PluginAccessibilityAnchorLocatorSchema, pid: pid_t
    ) -> Result<CGRect, Failure> {
        guard let window = focusedWindow(pid: pid) else {
            ComputerUseMonitor.shared.note(lane: .pointer, refused: "captureAnchor", pid: pid, reason: .noFocusedWindow)
            return .failure(.noFocusedWindow)
        }
        guard let element = locate(locator, under: window.element) else {
            ComputerUseMonitor.shared.note(lane: .pointer, refused: "captureAnchor", pid: pid, reason: .anchorNotUnique)
            return .failure(.anchorNotUnique)
        }
        guard let frame = AX.frame(of: element), frame.width > 1, frame.height > 1 else {
            ComputerUseMonitor.shared.note(
                lane: .pointer, refused: "captureAnchor", pid: pid,
                reason: .elementHasNoFrame)
            return .failure(.anchorHasNoFrame)
        }
        ComputerUseMonitor.shared.note(
            lane: .pointer, act: "captureAnchor", pid: pid,
            detail: locator.identifier)
        return .success(frame)
    }

    /// Bounded BFS for one unique element matching the closed locator.
    static func locate(
        _ locator: PluginAccessibilityAnchorLocatorSchema, under root: AXUIElement
    ) -> AXUIElement? {
        locateCore(
            locator, root: root,
            children: { AX.children($0) },
            role: { AX.string($0, kAXRoleAttribute as String) },
            identifier: { AX.string($0, kAXIdentifierAttribute as String) },
            title: { AX.string($0, kAXTitleAttribute as String) },
            value: { AX.string($0, kAXValueAttribute as String) })
    }

    /// The matching rule, over any tree. Generic so the budgets and the
    /// exactly-one rule are pinned by tests without AX inter-process traffic —
    /// the same trick `AXTreeWalker.walkCore` uses.
    static func locateCore<Node>(
        _ locator: PluginAccessibilityAnchorLocatorSchema,
        root: Node,
        children: (Node) -> [Node],
        role: (Node) -> String?,
        identifier: (Node) -> String?,
        title: (Node) -> String?,
        value: (Node) -> String?
    ) -> Node? {
        let wantedRole = axName(locator.role)
        var matches: [Node] = []
        var queue = [root]
        var seen = 0
        while let current = queue.first, seen < containerBudget {
            queue.removeFirst()
            seen += 1
            if role(current) == wantedRole, identifier(current) == locator.identifier {
                matches.append(current)
            }
            queue.append(contentsOf: children(current))
        }
        guard matches.count == 1 else { return nil }
        let container = matches[0]
        guard locator.descendantRole != nil
                || locator.descendantIdentifier != nil
                || locator.descendantTitle != nil
                || locator.descendantLabelText != nil
        else { return container }

        let descendantRole = locator.descendantRole.map(axName)
        var descendants: [Node] = []
        var inner = children(container)
        var innerSeen = 0
        while let current = inner.first, innerSeen < descendantBudget {
            inner.removeFirst()
            innerSeen += 1
            let currentRole = role(current)
            let id = identifier(current)
            let currentTitle = title(current)
            let currentValue = value(current)
            let roleOK = descendantRole.map { currentRole == $0 } ?? true
            let idOK = locator.descendantIdentifier.map { id == $0 } ?? true
            let titleOK = locator.descendantTitle.map { currentTitle == $0 } ?? true
            let labelOK = locator.descendantLabelText.map {
                currentTitle == $0 || currentValue == $0
            } ?? true
            if roleOK && idOK && titleOK && labelOK { descendants.append(current) }
            inner.append(contentsOf: children(current))
        }
        return descendants.count == 1 ? descendants[0] : nil
    }

    static func axName(_ role: PluginAccessibilityRole) -> String {
        "AX" + role.rawValue.prefix(1).uppercased() + role.rawValue.dropFirst()
    }
}

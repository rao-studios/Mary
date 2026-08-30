//
//  MaryHands+Pointer.swift
//  MaryBrain
//
//  THE POINTER LANE. Normalized (0,0)–(1,1) points become screen points
//  against the focused window, or against a rectangle captured earlier in
//  this same transaction. Events post to the pid — never a global tap —
//  matching the media-surface press ladder that already proved the click
//  belongs to the process that owns the element.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAmbient
import MaryFoundation
import os

extension MaryHands {

    /// Coordinate spaces captured during one foreground transaction.
    /// Reset by the executor before the first step so a previous recipe
    /// cannot aim this one.
    private static let spaces = OSAllocatedUnfairLock<[String: CGRect]>(initialState: [:])

    static func resetPointerSpaces() {
        spaces.withLock { $0 = [:] }
    }

    // MARK: - Acts

    static func pointerMove(
        x: Double, y: Double, space: String, pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        switch screenPoint(x: x, y: y, space: space, pid: pid, application: application) {
        case .failure(let error): return .failure(error)
        case .success(let point):
            guard postMouse(type: .mouseMoved, at: point, button: .left, pid: pid) else {
                return .failure(.stepFailed("the pointer couldn't move in \(application)"))
            }
            return .success(())
        }
    }

    static func pointerClick(
        x: Double, y: Double, space: String,
        button: PluginPointerButton, count: Int,
        pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        switch screenPoint(x: x, y: y, space: space, pid: pid, application: application) {
        case .failure(let error): return .failure(error)
        case .success(let point):
            let clicks = max(1, min(count, 3))
            let cgButton: CGMouseButton = button == .right ? .right : .left
            let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
            for n in 1...clicks {
                guard postMouse(type: down, at: point, button: cgButton, pid: pid, clickCount: n),
                      postMouse(type: up, at: point, button: cgButton, pid: pid, clickCount: n)
                else {
                    return .failure(.stepFailed("the click didn't reach \(application)"))
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            return .success(())
        }
    }

    static func pointerDrag(
        fromX: Double, fromY: Double, toX: Double, toY: Double, space: String,
        pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        let from: CGPoint
        let to: CGPoint
        switch screenPoint(x: fromX, y: fromY, space: space, pid: pid, application: application) {
        case .failure(let error): return .failure(error)
        case .success(let point): from = point
        }
        switch screenPoint(x: toX, y: toY, space: space, pid: pid, application: application) {
        case .failure(let error): return .failure(error)
        case .success(let point): to = point
        }
        guard postMouse(type: .leftMouseDown, at: from, button: .left, pid: pid),
              postMouse(type: .leftMouseDragged, at: to, button: .left, pid: pid),
              postMouse(type: .leftMouseUp, at: to, button: .left, pid: pid)
        else {
            return .failure(.stepFailed("the drag didn't reach \(application)"))
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return .success(())
    }

    static func pointerSquareDrag(
        x: Double, y: Double, side: Double, space: String,
        pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        let clamped = min(max(side, 0), 1)
        return await pointerDrag(
            fromX: x, fromY: y, toX: x + clamped, toY: y + clamped, space: space,
            pid: pid, application: application)
    }

    static func pointerScroll(
        x: Double, y: Double, space: String, deltaX: Double, deltaY: Double,
        pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        switch screenPoint(x: x, y: y, space: space, pid: pid, application: application) {
        case .failure(let error): return .failure(error)
        case .success(let point):
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let event = CGEvent(
                    scrollWheelEvent2Source: source,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(deltaY.rounded()),
                    wheel2: Int32(deltaX.rounded()),
                    wheel3: 0)
            else {
                return .failure(.stepFailed("the scroll couldn't be posted"))
            }
            event.location = point
            event.postToPid(pid)
            try? await Task.sleep(nanoseconds: 120_000_000)
            return .success(())
        }
    }

    static func captureAnchor(
        locator: PluginAccessibilityAnchorLocatorSchema,
        name: String,
        pid: pid_t,
        application: String
    ) -> Result<Void, PluginManagedUIError> {
        let app = AXUIElementCreateApplication(pid)
        guard let window = focusedWindow(of: app) else {
            return .failure(.pointerUnavailable("\(application) has no focused window"))
        }
        guard let element = locate(locator, under: window),
              let frame = AX.frame(of: element),
              frame.width > 1, frame.height > 1
        else {
            return .failure(.pointerUnavailable(
                "nothing unique matched that control in \(application)"))
        }
        spaces.withLock { $0[name] = frame }
        return .success(())
    }

    // MARK: - Coordinates

    private static func screenPoint(
        x: Double, y: Double, space: String, pid: pid_t, application: String
    ) -> Result<CGPoint, PluginManagedUIError> {
        let bounds: CGRect
        if space == "content" || space.isEmpty {
            guard let window = focusedWindow(of: AXUIElementCreateApplication(pid)),
                  let frame = AX.frame(of: window)
            else {
                return .failure(.pointerUnavailable("\(application) has no focused window"))
            }
            bounds = frame
        } else if let captured = spaces.withLock({ $0[space] }) {
            bounds = captured
        } else {
            return .failure(.pointerUnavailable("no captured region named \(space)"))
        }
        let nx = min(max(x, 0), 1)
        let ny = min(max(y, 0), 1)
        return .success(CGPoint(
            x: (bounds.minX + nx * bounds.width).rounded(),
            y: (bounds.minY + ny * bounds.height).rounded()))
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let window = value, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return (window as! AXUIElement)
    }

    private static func postMouse(
        type: CGEventType, at point: CGPoint, button: CGMouseButton,
        pid: pid_t, clickCount: Int = 1
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: point, mouseButton: button)
        else { return false }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.postToPid(pid)
        return true
    }

    /// Bounded BFS for one unique element matching the closed locator.
    private static func locate(
        _ locator: PluginAccessibilityAnchorLocatorSchema, under root: AXUIElement
    ) -> AXUIElement? {
        let wantedRole = axName(locator.role)
        var matches: [AXUIElement] = []
        var queue = [root]
        var seen = 0
        while let current = queue.first, seen < 400 {
            queue.removeFirst()
            seen += 1
            if AX.string(current, kAXRoleAttribute as String) == wantedRole,
               AX.string(current, kAXIdentifierAttribute as String) == locator.identifier {
                matches.append(current)
            }
            queue.append(contentsOf: AX.children(current))
        }
        guard matches.count == 1 else { return nil }
        let container = matches[0]
        guard locator.descendantRole != nil
                || locator.descendantIdentifier != nil
                || locator.descendantTitle != nil
                || locator.descendantLabelText != nil
        else { return container }

        let descendantRole = locator.descendantRole.map(axName)
        var descendants: [AXUIElement] = []
        var inner = AX.children(container)
        var innerSeen = 0
        while let current = inner.first, innerSeen < 200 {
            inner.removeFirst()
            innerSeen += 1
            let role = AX.string(current, kAXRoleAttribute as String)
            let id = AX.string(current, kAXIdentifierAttribute as String)
            let title = AX.string(current, kAXTitleAttribute as String)
            let value = AX.string(current, kAXValueAttribute as String)
            let roleOK = descendantRole.map { role == $0 } ?? true
            let idOK = locator.descendantIdentifier.map { id == $0 } ?? true
            let titleOK = locator.descendantTitle.map { title == $0 } ?? true
            let labelOK = locator.descendantLabelText.map {
                title == $0 || value == $0
            } ?? true
            if roleOK && idOK && titleOK && labelOK { descendants.append(current) }
            inner.append(contentsOf: AX.children(current))
        }
        return descendants.count == 1 ? descendants[0] : nil
    }

    private static func axName(_ role: PluginAccessibilityRole) -> String {
        "AX" + role.rawValue.prefix(1).uppercased() + role.rawValue.dropFirst()
    }
}

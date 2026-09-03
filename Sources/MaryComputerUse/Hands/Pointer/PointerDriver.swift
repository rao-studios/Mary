//
//  PointerDriver.swift
//  MaryComputerUse
//
//  WHAT: Normalized points become pid-posted mouse events.
//  IN:   a coordinate space (the focused window, or a captured anchor)
//  OUT:  move / click / drag / scroll
//  PIN:  NEVER A GLOBAL TAP. Every event is posted to one pid, so a recipe
//        that mis-aims cannot click something in another application. The
//        spaces are a VALUE the caller owns for one transaction — a previous
//        recipe must not be able to aim this one.
//

import ApplicationServices
import CoreGraphics
import Foundation

public enum PointerDriver {

    /// Coordinate spaces captured during one foreground transaction.
    ///
    /// PIN: a value, not a static. The executor makes one per transaction and
    /// it dies with it, which is the guarantee "reset before the first step"
    /// used to be asking a lock to remember.
    public struct Spaces: Sendable, Equatable {
        private var frames: [String: CGRect] = [:]

        public init() {}

        public mutating func capture(_ name: String, frame: CGRect) {
            frames[name] = frame
        }

        public func bounds(named name: String) -> CGRect? { frames[name] }

        public var names: [String] { frames.keys.sorted() }
    }

    public enum Failure: Error, Equatable, Sendable {
        case noFocusedWindow
        case noCapturedSpace(String)
        case eventNotCreated
    }

    // MARK: - Coordinates

    /// Normalized (0…1) to a screen point inside `bounds`. Pure arithmetic:
    /// clamp, scale, round. Out-of-range is clamped rather than refused —
    /// a recipe aiming at 1.2 means the edge, not an error.
    public static func screenPoint(x: Double, y: Double, in bounds: CGRect) -> CGPoint {
        let nx = min(max(x, 0), 1)
        let ny = min(max(y, 0), 1)
        return CGPoint(
            x: (bounds.minX + nx * bounds.width).rounded(),
            y: (bounds.minY + ny * bounds.height).rounded())
    }

    /// Which rectangle a step's `space` names. "content" (or empty) is the
    /// focused window; anything else must have been captured this transaction.
    public static func resolve(
        x: Double, y: Double, space: String, spaces: Spaces, pid: pid_t,
        focusedWindowFrame: (pid_t) -> CGRect? = { AccessibilityAnchorLocator.focusedWindow(pid: $0)?.frame }
    ) -> Result<CGPoint, Failure> {
        let bounds: CGRect
        if space == "content" || space.isEmpty {
            guard let frame = focusedWindowFrame(pid) else {
                ComputerUseMonitor.shared.note(lane: .pointer, refused: "resolve", pid: pid, reason: .noFocusedWindow)
                return .failure(.noFocusedWindow)
            }
            bounds = frame
        } else if let captured = spaces.bounds(named: space) {
            bounds = captured
        } else {
            ComputerUseMonitor.shared.note(
                lane: .pointer, refused: "resolve", pid: pid,
                reason: .noCapturedSpace(space))
            return .failure(.noCapturedSpace(space))
        }
        return .success(screenPoint(x: x, y: y, in: bounds))
    }

    // MARK: - Acts

    @discardableResult
    public static func move(to point: CGPoint, pid: pid_t) -> Bool {
        report("move", postMouse(type: .mouseMoved, at: point, button: .left, pid: pid),
               pid: pid, detail: describe(point))
    }

    /// `count` down/up pairs, each carrying its click index so the target sees
    /// a real double-click rather than two singles.
    @discardableResult
    public static func click(
        at point: CGPoint, button: PluginPointerButton, count: Int, pid: pid_t
    ) -> Bool {
        let clicks = max(1, min(count, 3))
        let cgButton: CGMouseButton = button == .right ? .right : .left
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        for n in 1...clicks {
            guard postMouse(type: down, at: point, button: cgButton, pid: pid, clickCount: n),
                  postMouse(type: up, at: point, button: cgButton, pid: pid, clickCount: n)
            else { return report("click", false, pid: pid, detail: describe(point)) }
        }
        return report(
            "click", true, pid: pid,
            detail: "\(describe(point)) \(button.rawValue)×\(clicks)")
    }

    @discardableResult
    public static func drag(from: CGPoint, to: CGPoint, pid: pid_t) -> Bool {
        let ok = postMouse(type: .leftMouseDown, at: from, button: .left, pid: pid)
            && postMouse(type: .leftMouseDragged, at: to, button: .left, pid: pid)
            && postMouse(type: .leftMouseUp, at: to, button: .left, pid: pid)
        return report("drag", ok, pid: pid, detail: "\(describe(from)) → \(describe(to))")
    }

    @discardableResult
    public static func scroll(
        at point: CGPoint, deltaX: Double, deltaY: Double, pid: pid_t
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(deltaY.rounded()),
                wheel2: Int32(deltaX.rounded()),
                wheel3: 0)
        else { return report("scroll", false, pid: pid, detail: describe(point)) }
        event.location = point
        event.postToPid(pid)
        return report(
            "scroll", true, pid: pid,
            detail: "\(describe(point)) by \(Int(deltaX.rounded())),\(Int(deltaY.rounded()))")
    }

    // MARK: - Reporting

    /// Every act reports itself, and a failed post is a NAMED refusal rather
    /// than a bare false travelling up the stack.
    @discardableResult
    private static func report(
        _ name: String, _ ok: Bool, pid: pid_t, detail: String
    ) -> Bool {
        if ok {
            ComputerUseMonitor.shared.note(lane: .pointer, act: name, pid: pid, detail: detail)
        } else {
            ComputerUseMonitor.shared.note(
                lane: .pointer, refused: name, pid: pid, reason: .eventNotCreated)
        }
        return ok
    }

    private static func describe(_ point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
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
}

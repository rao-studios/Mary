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

    /// Where the pointer actually is right now.
    public static var location: CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// Put the POINTER ITSELF over a point, so what is under it knows.
    ///
    /// PIN: A REAL MOVE, THROUGH THE SAME TAP A MOUSE USES, and it is the only act here
    /// that does not go to a single pid. Both cheaper ways were measured and both fail:
    /// a `mouseMoved` posted to the process leaves the cursor where it was, so a page
    /// asking the window server where the pointer is still says "not over the video" and
    /// keeps a video's controls hidden; and `CGWarpMouseCursorPosition` moves the cursor
    /// but GENERATES NO EVENT, so the page is never told it moved and reveals nothing
    /// until something else wakes it — which is why the two together worked
    /// intermittently and unpredictably.
    ///
    /// The blast radius is a POINTER MOVE, not a click: nothing is pressed, the movement
    /// is exactly what the user would do with their own hand, and it is visible on
    /// screen while it happens. The caller puts it back — see `restore(to:)`.
    @discardableResult
    public static func hover(at point: CGPoint, pid: pid_t) -> Bool {
        // A TRAVEL, SPREAD OVER TIME — not a jump, and not a burst.
        //
        // PIN: THE PAUSES BETWEEN STEPS ARE THE POINT. Events posted in the same instant
        // are coalesced by the window server into a single move, and a page that hides a
        // video's controls on a timer treats one move at a position the pointer is
        // already at as nothing happening — measured: the cursor read the same before and
        // after a three-step reveal, and the transport stayed hidden. Real movement
        // arrives spread across frames, so this does too.
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return report("hover", false, pid: pid, detail: describe(point))
        }
        // PIN: SUPPRESSION OFF, OR THE MOVES ARRIVE AND CHANGE NOTHING. After a posted
        // mouse event, the window server suppresses local mouse handling for a quarter
        // of a second by default — which is most of the time a reveal has, so a page
        // that decides to show a video's controls from pointer movement never sees the
        // movement it was sent. This is the setting that makes a synthetic hover behave
        // like a hand.
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let travel = 180.0
        let count = 22
        var ok = true
        for step in 0...count {
            let progress = Double(step) / Double(count)
            let eased = progress * progress * (3 - 2 * progress)
            let here = CGPoint(
                x: point.x - travel * (1 - eased),
                y: point.y - travel * 0.45 * (1 - eased))
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: here, mouseButton: .left)
            else { ok = false; break }
            event.post(tap: .cghidEventTap)
            // One display frame between steps.
            usleep(16_000)
        }
        return report("hover", ok, pid: pid, detail: describe(point))
    }

    /// Put the cursor back where it was found. Nil is a no-op — a caller that could not
    /// read the position must not invent one.
    public static func restore(to point: CGPoint?) {
        guard let point else { return }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)
        else { return }
        event.post(tap: .cghidEventTap)
        ComputerUseMonitor.shared.note(
            lane: .pointer, act: "restoreCursor", detail: describe(point))
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

    /// A click delivered the way the hardware delivers one.
    ///
    /// PIN: THE ONE EXCEPTION TO "NEVER A GLOBAL TAP", AND IT IS EARNED BY MEASUREMENT.
    /// A pid-posted click is invisible to a rendered web page's hit testing — measured
    /// on YouTube, where a correctly aimed press reported success and moved nothing,
    /// repeatedly. The cursor is warped onto the target first, so the event lands where
    /// the pointer already visibly is; that is what bounds the risk a global tap
    /// otherwise carries, because the click goes exactly where the user can see it go.
    /// Everything that CAN be driven by a pid-posted event still is: this is for page
    /// content and nothing else.
    @discardableResult
    public static func clickThroughHID(
        at point: CGPoint, button: PluginPointerButton, count: Int
    ) -> Bool {
        let clicks = max(1, min(count, 3))
        let cgButton: CGMouseButton = button == .right ? .right : .left
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return report("clickHID", false, pid: 0, detail: describe(point))
        }
        // Same suppression release as `hover`, and for the same measured reason: without
        // it the window server ignores local mouse handling for a quarter second after a
        // posted event, which is exactly the window a press lands in.
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        for n in 1...clicks {
            guard let downEvent = CGEvent(
                    mouseEventSource: source, mouseType: down,
                    mouseCursorPosition: point, mouseButton: cgButton),
                  let upEvent = CGEvent(
                    mouseEventSource: source, mouseType: up,
                    mouseCursorPosition: point, mouseButton: cgButton)
            else { return report("clickHID", false, pid: 0, detail: describe(point)) }
            downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            downEvent.post(tap: .cghidEventTap)
            // A real press has a duration. A down and an up in the same instant is
            // something no hand produces, and some pages treat it as neither.
            usleep(40_000)
            upEvent.post(tap: .cghidEventTap)
        }
        return report(
            "clickHID", true, pid: 0,
            detail: "\(describe(point)) \(button.rawValue)×\(clicks)")
    }

    /// A short travel to a point, the way a hand arrives at one.
    ///
    /// PIN: `hover` STARTS 180 POINTS AWAY, AND SOMETIMES THAT IS THE PROBLEM. Its long
    /// approach is what wakes a video's transport, but the same approach sweeps across
    /// whatever lies between — measured on a player, where reaching the volume control
    /// from the far side passed over the picture and dismissed the very slider the move
    /// was for. This one starts where the pointer already is, so it disturbs nothing on
    /// the way, and it is still real movement rather than a jump.
    @discardableResult
    public static func glideThroughHID(to point: CGPoint, steps: Int = 8) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return report("glide", false, pid: 0, detail: describe(point))
        }
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let from = location ?? point
        let count = max(2, steps)
        for step in 1...count {
            let progress = Double(step) / Double(count)
            let eased = progress * progress * (3 - 2 * progress)
            let here = CGPoint(
                x: from.x + (point.x - from.x) * eased,
                y: from.y + (point.y - from.y) * eased)
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: here, mouseButton: .left)
            else { return report("glide", false, pid: 0, detail: describe(point)) }
            event.post(tap: .cghidEventTap)
            usleep(16_000)
        }
        return report("glide", true, pid: 0, detail: describe(point))
    }

    /// A press, a travel, and a release — through the same tap the hardware uses.
    ///
    /// PIN: A PID-POSTED DRAG IS INVISIBLE TO A PAGE, exactly as a pid-posted click is,
    /// and for the same reason: rendered content hit-tests against the real pointer.
    /// A slider dragged that way reports success and moves nothing. The pointer is put
    /// on the handle first, so the gesture is where it can be seen happening.
    /// THE MOVE IS IN STEPS, because a control that follows the pointer needs to be
    /// told where it went, not merely where it ended up.
    @discardableResult
    public static func dragThroughHID(
        from: CGPoint, to: CGPoint, duration: Double = 0.22
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return report("dragHID", false, pid: 0, detail: describe(to))
        }
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        func post(_ type: CGEventType, _ point: CGPoint) -> Bool {
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)
            else { return false }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
            return true
        }

        guard post(.mouseMoved, from), post(.leftMouseDown, from) else {
            return report("dragHID", false, pid: 0, detail: describe(to))
        }
        let steps = max(2, Int((duration * 60).rounded()))
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let eased = progress * progress * (3 - 2 * progress)
            let here = CGPoint(
                x: from.x + (to.x - from.x) * eased,
                y: from.y + (to.y - from.y) * eased)
            guard post(.leftMouseDragged, here) else {
                // A BUTTON LEFT DOWN IS WORSE THAN A FAILED DRAG. Release wherever the
                // gesture got to before reporting.
                _ = post(.leftMouseUp, here)
                return report("dragHID", false, pid: 0, detail: describe(to))
            }
            usleep(UInt32(duration * 1_000_000 / Double(steps)))
        }
        let released = post(.leftMouseUp, to)
        return report("dragHID", released, pid: 0, detail: "\(describe(from)) → \(describe(to))")
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

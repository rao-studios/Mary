//
//  PageElementActions.swift
//  MaryAdapter
//
//  Split out of PageElementReader.swift (docs/DECOMPOSITION.md
//  Wave 2) — pure relocation, no declaration changed.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// PRESSING AND REVEALING — the hand's mechanics, kept beside the eye that
/// found the target.
///
/// This lives in the kit rather than in the recipe that calls it for the
/// reason `SafariWebSurface`'s header states: "open a tab, find the editable
/// region, put text in it" is machine capability, and so is "press the
/// element you just resolved". The recipe layer owns the choreography around
/// it — the stage lease, verified activation, the re-read, the receipt.
public enum PageElementActions {

    /// Ask AX to focus the live element and prove the resulting state. There
    /// is intentionally no keyboard fallback: without focus, a key would go
    /// to whichever page control happened to own it before this request.
    @discardableResult
    public static func focus(_ element: PageElement) -> Bool {
        guard element.isEnabled else { return false }
        if PageElementReader.boolean(
            element.axElement, kAXFocusedAttribute) == true {
            return true
        }
        guard PageElementReader.isSettable(
                element.axElement, kAXFocusedAttribute),
              AXUIElementSetAttributeValue(
                element.axElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue) == .success
        else { return false }
        // A successful focus setter is not proof on browser AX proxies; read
        // the state back before claiming that subsequent input has a target.
        return PageElementReader.boolean(
            element.axElement, kAXFocusedAttribute) == true
    }

    /// Perform one AX-declared step. No arrow-key approximation is used: an
    /// unfocused or stale control must not turn into page navigation.
    @discardableResult
    public static func increment(_ element: PageElement) -> Bool {
        performDeclaredAction(
            kAXIncrementAction as String,
            on: element,
            wasOffered: element.offersIncrement)
    }

    @discardableResult
    public static func decrement(_ element: PageElement) -> Bool {
        performDeclaredAction(
            kAXDecrementAction as String,
            on: element,
            wasOffered: element.offersDecrement)
    }

    /// Move an adjustable control to a normalized position.
    ///
    /// A live, settable AX range is the only path in this shared AX helper.
    /// Pointer fallback belongs to the browser interaction executor, whose
    /// Remote Hands session pins the exact process and window, detects human
    /// interruption, revalidates displays, and restores focus and cursor.
    @discardableResult
    public static func setFraction(
        _ fraction: Double,
        of element: PageElement
    ) -> Bool {
        guard element.isEnabled,
              value(
                forFraction: fraction,
                minimum: 0,
                maximum: 1) != nil
        else { return false }

        return setAXFraction(fraction, of: element)
    }

    @discardableResult
    public static func setMinimum(_ element: PageElement) -> Bool {
        setFraction(0, of: element)
    }

    @discardableResult
    public static func setMaximum(_ element: PageElement) -> Bool {
        setFraction(1, of: element)
    }

    /// Set one exact raw range value while proving that the bounds used to
    /// author it are still the live bounds. Unlike normalizing to a fraction,
    /// this cannot turn "90 seconds" into 180 when a media duration changes
    /// between enumeration and mutation.
    @discardableResult
    public static func setValue(
        _ target: Double,
        of element: PageElement,
        expectedMinimum: Double,
        expectedMaximum: Double
    ) -> Bool {
        guard target.isFinite,
              expectedMinimum.isFinite,
              expectedMaximum.isFinite,
              expectedMinimum < expectedMaximum,
              (expectedMaximum - expectedMinimum).isFinite,
              target >= expectedMinimum,
              target <= expectedMaximum else { return false }
        return setAXValue(
            target,
            of: element,
            expectedMinimum: expectedMinimum,
            expectedMaximum: expectedMaximum)
    }

    /// Pure range interpolation. Invalid fractions and unproven ranges refuse
    /// instead of clamping a malformed model or page value into an action.
    public static func value(
        forFraction fraction: Double,
        minimum: Double,
        maximum: Double
    ) -> Double? {
        guard fraction.isFinite,
              (0 ... 1).contains(fraction),
              minimum.isFinite,
              maximum.isFinite,
              minimum < maximum,
              (maximum - minimum).isFinite
        else { return nil }
        if fraction == 0 { return minimum }
        if fraction == 1 { return maximum }
        let result = minimum + ((maximum - minimum) * fraction)
        return result.isFinite ? result : nil
    }

    /// Pure screen geometry for the bounded pointer fallback. Fractions zero
    /// and one are inset from the track's ends, never placed on or outside its
    /// border. A vertical range follows the conventional screen mapping:
    /// minimum at the bottom, maximum at the top.
    public static func screenPoint(
        forFraction fraction: Double,
        in frame: CGRect,
        orientation: PageElementOrientation
    ) -> CGPoint? {
        guard fraction.isFinite,
              (0 ... 1).contains(fraction),
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 2,
              frame.height > 2
        else { return nil }

        let edgeInset = min(
            CGFloat(4), min(frame.width, frame.height) / 4)
        guard edgeInset > 0 else { return nil }
        let amount = CGFloat(fraction)
        let point: CGPoint
        switch orientation {
        case .horizontal:
            let span = frame.width - (2 * edgeInset)
            point = CGPoint(
                x: frame.minX + edgeInset + (span * amount),
                y: frame.midY)
        case .vertical:
            let span = frame.height - (2 * edgeInset)
            point = CGPoint(
                x: frame.midX,
                y: frame.maxY - edgeInset - (span * amount))
        }
        guard point.x > frame.minX,
              point.x < frame.maxX,
              point.y > frame.minY,
              point.y < frame.maxY
        else { return nil }
        return point
    }

    private static func performDeclaredAction(
        _ action: String,
        on element: PageElement,
        wasOffered: Bool
    ) -> Bool {
        guard element.isEnabled,
              wasOffered,
              PageElementReader.actionNames(of: element.axElement)
                .contains(action)
        else { return false }
        return AXUIElementPerformAction(
            element.axElement, action as CFString) == .success
    }

    private static func setAXFraction(
        _ fraction: Double,
        of element: PageElement
    ) -> Bool {
        guard PageElementReader.isSettable(
                element.axElement, kAXValueAttribute),
              let minimum = PageElementReader.numeric(
                element.axElement, kAXMinValueAttribute),
              let maximum = PageElementReader.numeric(
                element.axElement, kAXMaxValueAttribute),
              let target = value(
                forFraction: fraction,
                minimum: minimum,
                maximum: maximum)
        else { return false }
        return setAXValue(
            target,
            of: element,
            expectedMinimum: minimum,
            expectedMaximum: maximum)
    }

    private static func setAXValue(
        _ target: Double,
        of element: PageElement,
        expectedMinimum: Double,
        expectedMaximum: Double
    ) -> Bool {
        guard element.isEnabled,
              PageElementReader.isSettable(
                element.axElement, kAXValueAttribute),
              PageElementReader.numeric(
                element.axElement, kAXMinValueAttribute) == expectedMinimum,
              PageElementReader.numeric(
                element.axElement, kAXMaxValueAttribute) == expectedMaximum
        else { return false }
        guard AXUIElementSetAttributeValue(
            element.axElement,
            kAXValueAttribute as CFString,
            NSNumber(value: target)) == .success
        else { return false }

        // Chromium can acknowledge this setter while leaving an HTML range
        // unchanged. A successful API return is therefore not an effect
        // receipt: read the live value back before allowing the caller to
        // skip its pinned pointer fallback.
        guard PageElementReader.numeric(
                element.axElement, kAXMinValueAttribute) == expectedMinimum,
              PageElementReader.numeric(
                element.axElement, kAXMaxValueAttribute) == expectedMaximum,
              let observed = PageElementReader.numeric(
                element.axElement, kAXValueAttribute)
        else { return false }
        let span = expectedMaximum - expectedMinimum
        let tolerance = max(abs(span) * 0.000_001, 0.000_001)
        return abs(observed - target) <= tolerance
    }

    /// AXPress first, then a real click at the element's measured midpoint.
    ///
    /// MEASURED on live pages, and the reason this is a ladder rather than a
    /// call: web controls commonly advertise `AXPress` and do nothing with
    /// it, while an embedded player's play button advertises no press action
    /// at all and only answers a click. This is `satisfyHumanCheck`'s proven
    /// shape, promoted from a one-off to the general case.
    @discardableResult
    public static func press(
        _ element: PageElement, pid: pid_t
    ) async -> Bool {
        if element.offersPress,
           AXUIElementPerformAction(
            element.axElement, kAXPressAction as CFString) == .success {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return true
        }
        let frame = element.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        let point = CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded())
        guard click(at: point, pid: pid) else { return false }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return true
    }

    /// One click at one measured point, aimed at one process.
    ///
    /// EXTRACTED SO THERE IS ONE DEFINITION, not because `press` was long.
    /// The web surface needs the same click to put a caret in an editor whose
    /// focus setter lied, and a second copy of these six lines is how two
    /// call sites start disagreeing about which tap to post to.
    ///
    /// The caller supplies the point and owns the question of whether it is a
    /// legal place to click — this one only knows how.
    @discardableResult
    public static func click(at point: CGPoint, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        // postToPid, never a global tap: the click belongs to the application
        // that owns the element, and nothing else on screen should see it.
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// Scroll something into view without pressing it. AX's own action is the
    /// only honest way: synthesizing a scroll at a coordinate would move
    /// whatever scroller happens to be under it.
    @discardableResult
    public static func reveal(_ element: PageElement) -> Bool {
        AXUIElementPerformAction(
            element.axElement, "AXScrollToVisible" as CFString) == .success
    }
}

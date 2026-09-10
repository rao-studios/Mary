//
//  MaryHands+Pointer.swift
//  MaryBrain
//
//  WHAT: Pointer lane — compiled steps become calls on the pointer driver.
//  IN:   MaryHands.swift
//  OUT:  PointerDriver / AccessibilityAnchorLocator (MaryComputerUse)
//  PIN:  TRANSLATION ONLY. No CGEvent, no AXUIElement, no coordinate maths
//        lives here — this file turns a driver's refusal into the sentence
//        Mary says, and owns the settle pauses between acts because those are
//        about the recipe's pacing, not about the pointer.
//
import Foundation
import MaryComputerUse
import MaryFoundation

extension MaryHands {

    // MARK: - Acts

    static func pointerMove(
        x: Double, y: Double, space: String, spaces: PointerDriver.Spaces,
        pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        switch PointerDriver.resolve(x: x, y: y, space: space, spaces: spaces, pid: pid) {
        case .failure(let error): return .failure(sentence(error, application: application))
        case .success(let point):
            guard PointerDriver.move(to: point, pid: pid) else {
                return .failure(.stepFailed("the pointer couldn't move in \(application)"))
            }
            return .success(())
        }
    }

    static func pointerClick(
        x: Double, y: Double, space: String, spaces: PointerDriver.Spaces,
        button: PluginPointerButton, count: Int,
        pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        switch PointerDriver.resolve(x: x, y: y, space: space, spaces: spaces, pid: pid) {
        case .failure(let error): return .failure(sentence(error, application: application))
        case .success(let point):
            guard PointerDriver.click(at: point, button: button, count: count, pid: pid) else {
                return .failure(.stepFailed("the click didn't reach \(application)"))
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            return .success(())
        }
    }

    static func pointerDrag(
        fromX: Double, fromY: Double, toX: Double, toY: Double, space: String,
        spaces: PointerDriver.Spaces, pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        let from: CGPoint
        let to: CGPoint
        switch PointerDriver.resolve(x: fromX, y: fromY, space: space, spaces: spaces, pid: pid) {
        case .failure(let error): return .failure(sentence(error, application: application))
        case .success(let point): from = point
        }
        switch PointerDriver.resolve(x: toX, y: toY, space: space, spaces: spaces, pid: pid) {
        case .failure(let error): return .failure(sentence(error, application: application))
        case .success(let point): to = point
        }
        guard PointerDriver.drag(from: from, to: to, pid: pid) else {
            return .failure(.stepFailed("the drag didn't reach \(application)"))
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return .success(())
    }

    static func pointerSquareDrag(
        x: Double, y: Double, side: Double, space: String,
        spaces: PointerDriver.Spaces, pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        let clamped = min(max(side, 0), 1)
        return await pointerDrag(
            fromX: x, fromY: y, toX: x + clamped, toY: y + clamped, space: space,
            spaces: spaces, pid: pid, application: application)
    }

    static func pointerScroll(
        x: Double, y: Double, space: String, spaces: PointerDriver.Spaces,
        deltaX: Double, deltaY: Double,
        pid: pid_t, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        switch PointerDriver.resolve(x: x, y: y, space: space, spaces: spaces, pid: pid) {
        case .failure(let error): return .failure(sentence(error, application: application))
        case .success(let point):
            guard PointerDriver.scroll(at: point, deltaX: deltaX, deltaY: deltaY, pid: pid) else {
                return .failure(.stepFailed("the scroll couldn't be posted"))
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            return .success(())
        }
    }

    /// Remember a control's frame under a name, so later steps can aim inside it.
    static func captureAnchor(
        locator: PluginAccessibilityAnchorLocatorSchema,
        name: String,
        spaces: inout PointerDriver.Spaces,
        pid: pid_t,
        application: String
    ) -> Result<Void, PluginManagedUIError> {
        switch AccessibilityAnchorLocator.anchorFrame(locator, pid: pid) {
        case .success(let frame):
            spaces.capture(name, frame: frame)
            return .success(())
        case .failure(.noFocusedWindow):
            return .failure(.pointerUnavailable("\(application) has no focused window"))
        case .failure(.anchorNotUnique), .failure(.anchorHasNoFrame):
            return .failure(.pointerUnavailable(
                "nothing unique matched that control in \(application)"))
        }
    }

    // MARK: - Refusals

    /// The driver reports what went wrong; the sentence is Mary's.
    private static func sentence(
        _ failure: PointerDriver.Failure, application: String
    ) -> PluginManagedUIError {
        switch failure {
        case .noFocusedWindow:
            return .pointerUnavailable("\(application) has no focused window")
        case .noCapturedSpace(let name):
            return .pointerUnavailable("no captured region named \(name)")
        case .eventNotCreated:
            return .stepFailed("the pointer event couldn't be created")
        }
    }
}

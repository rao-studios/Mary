//
//  MaryHands.swift
//  MaryBrain
//
//  WHAT: Physical acts a compiled recipe may perform.
//  IN:   PluginManagedUIExecutor compiled steps
//  OUT:  keys / text / pause / window notice / pointer
//  PIN:  Compiler resolves expressions; this file denormalizes them. Every act
//        belongs to MaryComputerUse — the brain decides WHAT to do and what to
//        say when it fails, never HOW to reach the machine.
//
import AppKit
import Foundation
import MaryComputerUse
import MaryFoundation

enum MaryHands {

    /// Perform one compiled step against an application already brought forward and verified.
    static func perform(
        _ step: PluginCompiledStep, pid: pid_t, application: String,
        spaces: inout PointerDriver.Spaces
    ) async -> Result<Void, PluginManagedUIError> {
        switch step {
        case .keyChord(let key, let modifiers):
            guard KeyChordPress.press(key: key, modifiers: modifiers) else {
                return .failure(.stepFailed("the keyboard shortcut couldn't be posted"))
            }
            // A chord that opens a menu or a window needs the application to
            // act on it before the next step assumes it did.
            try? await Task.sleep(nanoseconds: 120_000_000)
            return .success(())

        case .typeText(let text):
            // THE TARGET PREFIX IS A GUARD, NOT AN ADDRESS.
            guard let bundleID = NSRunningApplication(processIdentifier: pid)?
                .bundleIdentifier
            else {
                return .failure(.stepFailed("\(application) is no longer running"))
            }
            let typed = await KeyboardTyper.typeIntoSelection(
                text, targetPrefix: bundleID)
            guard typed else {
                return .failure(.stepFailed("the text didn't reach \(application)"))
            }
            return .success(())

        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return .success(())

        case .rebindFocusedWindow(let requiresChange):
            return await rebind(pid: pid, requiresChange: requiresChange,
                                application: application)

        case .pointerMove(let x, let y, let space):
            return await pointerMove(
                x: x, y: y, space: space, spaces: spaces, pid: pid, application: application)

        case .pointerClick(let x, let y, let space, let button, let count):
            return await pointerClick(
                x: x, y: y, space: space, spaces: spaces, button: button, count: count,
                pid: pid, application: application)

        case .pointerDrag(let fromX, let fromY, let toX, let toY, let space):
            return await pointerDrag(
                fromX: fromX, fromY: fromY, toX: toX, toY: toY, space: space,
                spaces: spaces, pid: pid, application: application)

        case .pointerSquareDrag(let x, let y, let side, let space):
            return await pointerSquareDrag(
                x: x, y: y, side: side, space: space,
                spaces: spaces, pid: pid, application: application)

        case .scroll(let x, let y, let space, let deltaX, let deltaY):
            return await pointerScroll(
                x: x, y: y, space: space, spaces: spaces, deltaX: deltaX, deltaY: deltaY,
                pid: pid, application: application)

        case .captureAccessibilityAnchor(let locator, let name):
            return captureAnchor(
                locator: locator, name: name, spaces: &spaces,
                pid: pid, application: application)
        }
    }

    /// Wait for the application's focused window, optionally insisting it is a DIFFERENT one than before.
    private static func rebind(
        pid: pid_t, requiresChange: Bool, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        let before = requiresChange
            ? AccessibilityAnchorLocator.focusedWindow(pid: pid)
            : nil

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let now = AccessibilityAnchorLocator.focusedWindow(pid: pid), now != before {
                return .success(())
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .failure(.stepFailed(
            requiresChange
                ? "\(application) never opened a new window"
                : "\(application) has no focused window"))
    }
}

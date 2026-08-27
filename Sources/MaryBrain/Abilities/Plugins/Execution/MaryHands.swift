//
//  MaryHands.swift
//  MaryBrain
//
//  THE HANDS. Every physical act a declared recipe can perform, and nothing
//  else — one function per compiled step, each of which either happened or
//  says why it did not.
//
//  WHAT SHE HAS HANDS FOR: keys, text, a pause, and noticing that a new window
//  arrived. That is the whole list, and it is short because it is the list
//  that needs no coordinates. A chord is a POSITION on the keyboard and lands
//  the same way on every display; typing goes wherever focus is. Neither one
//  can be aimed at the wrong pixel, because neither one is aimed.
//
//  WHAT SHE DOES NOT: the mouse. Moving, clicking, dragging and scrolling all
//  need a point, a point needs a coordinate space, and a coordinate space
//  needs the whole apparatus that resolves one — window bounds, display
//  scaling, captured anchors, and a verification ladder to notice when the
//  point landed somewhere else. That apparatus is a lane of its own and it is
//  not in this cut. The grammar still HAS the pointer steps, because the
//  grammar describes what a recipe may say rather than what Mary can currently
//  do; `PluginCompiledStep` is where the two meet, and a pointer step is
//  refused there, at compile time, before anything is touched.
//
//  THE SEAM IS THE COMPILER, NOT A FLAG. When the pointer lane lands it adds
//  cases to `PluginCompiledStep` and arms to this file; nothing above changes,
//  and no `if handsAvailable` has to be threaded through the transaction.
//

import AppKit
import ApplicationServices
import Foundation
import MaryAdapters
import MaryFoundation

enum MaryHands {

    /// Perform one compiled step against an application already brought
    /// forward and verified.
    ///
    /// TAKES A PID IT DOES NOT ACTIVATE. Focus is the transaction's business,
    /// established once before the first step and re-checked after any step
    /// that can move it; a hands function that activated on its own would let
    /// a five-step recipe bring a window forward five times.
    static func perform(
        _ step: PluginCompiledStep, pid: pid_t, application: String
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
            // THE TARGET PREFIX IS A GUARD, NOT AN ADDRESS. The typer checks
            // that focus is still where the transaction put it before each
            // burst; a nil bundle id (a process that quit between the
            // activation and here) means it cannot check, and the honest
            // answer to that is to refuse rather than type into whatever is
            // in front now.
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
        }
    }

    /// Wait for the application's focused window, optionally insisting it is a
    /// DIFFERENT one than before.
    ///
    /// THE "DIFFERENT ONE" CLAUSE IS THE WHOLE POINT. A recipe that presses
    /// ⌘N and then types has to know the typing goes into the NEW document;
    /// without the identity check it would accept the old window that never
    /// went away — the application was simply too slow — and write the user's
    /// text into the note they were already reading.
    private static func rebind(
        pid: pid_t, requiresChange: Bool, application: String
    ) async -> Result<Void, PluginManagedUIError> {
        let app = AXUIElementCreateApplication(pid)
        let before = requiresChange ? focusedWindowIdentity(of: app) : nil

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let now = focusedWindowIdentity(of: app), now != before {
                return .success(())
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .failure(.stepFailed(
            requiresChange
                ? "\(application) never opened a new window"
                : "\(application) has no focused window"))
    }

    /// A focused window's identity for the purpose of noticing it CHANGED.
    ///
    /// The `AXUIElement` itself is the honest identity — two references to the
    /// same window compare equal and to different windows do not — so this is
    /// deliberately not the title. Titles collide constantly ("Untitled"), and
    /// a title comparison would report no change for exactly the case the
    /// caller cares about most: a second new document.
    private static func focusedWindowIdentity(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let window = value, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return (window as! AXUIElement)
    }
}

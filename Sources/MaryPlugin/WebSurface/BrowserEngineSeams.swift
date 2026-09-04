//
//  BrowserEngineSeams.swift
//  MaryPlugin
//
//  WHAT: The four things the browser engine can do to a machine, as protocols.
//  IN:   BrowserEngine.Seams
//  OUT:  .live wires each to MaryComputerUse
//  PIN:  SEAMS SO THE ENGINE IS TESTABLE WITHOUT A BROWSER. Every refusal path and
//        every verification failure has to be reachable in a test, and none of them is
//        reachable if the engine can only be exercised by driving Safari by hand.
//        The live implementations are thin on purpose — they add nothing the machine
//        layer does not already do, so the seam costs no behaviour.
//

import AppKit
import CoreGraphics
import Foundation
import MaryComputerUse
import MaryFoundation

/// Reading and driving the browser's own shell.
public protocol BrowserShellReading: Sendable {
    func read(pid: pid_t, registration: WebSurfaceRegistration) async -> WebSurfaceAX.Reading?
    func openLocation(_ address: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool
    /// Press a shell control by its declared label.
    func press(label: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool
}

/// Reading the page itself.
public protocol PagePerceiving: Sendable {
    func read(
        pid: pid_t, windowID: CGWindowID?, pageFrame: CGRect,
        intent: VisionPageReader.Intent, appName: String, windowTitle: String,
        previousFraction: Double?, previousElapsed: TimeInterval?
    ) async throws -> VisionPageReader.Reading
}

/// The pointer.
public protocol BrowserHands: Sendable {
    func move(to point: CGPoint, pid: pid_t) async
    func click(at point: CGPoint, pid: pid_t) async
    func scroll(at point: CGPoint, by delta: Double, pid: pid_t) async
    /// Put the pointer itself over a point. See PointerDriver.hover.
    func hover(at point: CGPoint, pid: pid_t) async
    /// Where the pointer was before any of this, so it can be put back.
    func cursorLocation() async -> CGPoint?
    func restoreCursor(to point: CGPoint?) async
}

public extension BrowserHands {
    /// Wake a player's transport by moving the pointer ACROSS its picture.
    ///
    /// PIN: TWO POINTS, NOT ONE. A player reveals its controls on mouse MOVEMENT, and a
    /// single event at a fixed coordinate is not movement — measured against YouTube,
    /// where one posted `mouseMoved` left the transport hidden and the page read as a
    /// video with no controls at all. Two events a few points apart is a move, and the
    /// second one is where the pointer is left so the controls stay up for the read.
    func reveal(over frame: CGRect, pid: pid_t) async {
        await reveal(over: frame, at: 0.35, pid: pid)
    }

    /// `depth` is how far down the captured region to land, as a fraction. Retries use
    /// different depths, because a page is only a player over part of what was captured
    /// and one fraction cannot be right for every layout.
    func reveal(over frame: CGRect, at depth: Double, pid: pid_t) async {
        // ONE TRAVEL, INTO THE PICTURE. `hover` already starts well outside the target
        // and moves in, which is the entry a player reveals on; a second hover before it
        // only spends time and moves the pointer somewhere the page has to react to
        // first.
        //
        // The middle of the PICTURE, which on a watch page is the upper half of what was
        // captured — the lower half is the title and comments, and hovering there
        // reveals nothing.
        let centre = CGPoint(
            x: frame.midX.rounded(),
            y: (frame.minY + frame.height * CGFloat(min(max(depth, 0.05), 0.95))).rounded())
        await hover(at: centre, pid: pid)
    }
}

/// Who holds the machine.
public protocol BrowserStaging: Sendable {
    func bringForward(pid: pid_t) async -> Bool
}

// MARK: - Live

struct LiveBrowserShell: BrowserShellReading {
    func read(pid: pid_t, registration: WebSurfaceRegistration) async -> WebSurfaceAX.Reading? {
        WebSurfaceAX.read(pid: pid, registration: registration)
    }

    /// Focus the address field, replace what is in it, and commit.
    ///
    /// PIN: THE FULL ADDRESS IS TYPED, SCHEME AND ALL. Both omniboxes autocomplete
    /// inline as you type, and a bare host can be completed to a different address
    /// between the last character and Return.
    func openLocation(
        _ address: String, pid: pid_t, registration: WebSurfaceRegistration
    ) async -> Bool {
        guard await focusAddressField(pid: pid, registration: registration) else { return false }
        // Select all, so typing replaces rather than appends.
        guard KeyChordPress.press(key: .a, modifiers: [.command]) else { return false }
        let typed = await KeyboardTyper.type(
            address, targetPrefix: registration.bundleIdentifiers.first ?? "")
        // A PARTIAL ADDRESS MUST NOT BE COMMITTED. Losing focus halfway through leaves
        // half a URL in the field, and pressing Return then navigates somewhere nobody
        // asked for — worse than not navigating at all.
        guard case .completed = typed else { return false }
        return KeyChordPress.press(key: .return, modifiers: [])
    }

    private func focusAddressField(
        pid: pid_t, registration: WebSurfaceRegistration
    ) async -> Bool {
        // The declared chord is the browser's OWN menu command for focusing its address
        // field. It is shell, not a site shortcut — the distinction the whole browsing
        // discipline turns on.
        KeyChordPress.press(
            key: registration.schema.addressFocusKey,
            modifiers: registration.schema.addressFocusModifiers)
    }

    func press(label: String, pid: pid_t, registration: WebSurfaceRegistration) async -> Bool {
        guard let snapshot = AXEngine.snapshot(pid: pid, options: .exhaustive) else { return false }
        var target: AXNodeSnapshot?
        for window in snapshot.windows {
            window.root?.forEachNode { node in
                guard target == nil else { return }
                if WebSurfaceRegistration.folded(node.label ?? "")
                    == WebSurfaceRegistration.folded(label), node.isEnabled {
                    target = node
                }
            }
        }
        guard let target, let frame = target.frame, frame.width > 1, frame.height > 1
        else { return false }
        // A shell button is a real control: click its middle, posted to this process.
        return PointerDriver.click(
            at: CGPoint(x: frame.midX.rounded(), y: frame.midY.rounded()),
            button: .left, count: 1, pid: pid)
    }
}

struct LivePagePerception: PagePerceiving {
    func read(
        pid: pid_t, windowID: CGWindowID?, pageFrame: CGRect,
        intent: VisionPageReader.Intent, appName: String, windowTitle: String,
        previousFraction: Double?, previousElapsed: TimeInterval?
    ) async throws -> VisionPageReader.Reading {
        // THE PIPELINE, NOT THE READER. A second perception lane joins there, and the
        // engine must not have to learn about it. See PagePerceptionPipeline.
        try await PagePerceptionPipeline.read(
            pid: pid, windowID: windowID, pageFrame: pageFrame, intent: intent,
            appName: appName, windowTitle: windowTitle,
            previousFraction: previousFraction, previousElapsed: previousElapsed)
    }
}

public struct LiveBrowserHands: BrowserHands {
    public init() {}

    public func move(to point: CGPoint, pid: pid_t) async {
        PointerDriver.move(to: point, pid: pid)
    }

    /// PIN: THROUGH THE SAME TAP A MOUSE USES, not posted to the process.
    ///
    /// A pid-posted click is invisible to rendered page content — measured repeatedly on
    /// YouTube, where a correctly aimed press on the play button reported success and
    /// moved nothing, in both delivery orders and with the cursor already on the target.
    /// The engine puts the pointer ON the control first, so the press goes exactly where
    /// the user can see the pointer sitting; that is what bounds a global tap's risk
    /// here. Browser CHROME is still pressed through Accessibility, which does work.
    public func click(at point: CGPoint, pid: pid_t) async {
        PointerDriver.clickThroughHID(at: point, button: .left, count: 1)
    }

    public func scroll(at point: CGPoint, by delta: Double, pid: pid_t) async {
        PointerDriver.scroll(at: point, deltaX: 0, deltaY: delta, pid: pid)
    }

    public func hover(at point: CGPoint, pid: pid_t) async {
        PointerDriver.hover(at: point, pid: pid)
    }

    public func cursorLocation() async -> CGPoint? { PointerDriver.location }

    public func restoreCursor(to point: CGPoint?) async { PointerDriver.restore(to: point) }
}

public struct LiveBrowserStaging: BrowserStaging {
    public init() {}

    public func bringForward(pid: pid_t) async -> Bool {
        await VerifiedActivation.bringForward(pid: pid).succeeded
    }
}

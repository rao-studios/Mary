//
//  VerifiedActivation.swift
//  MaryComputerUse
//
//  WHAT: Bring an application's WINDOW to the front and prove it — the one stage faculty.
//  IN:   a pid or a bundle id
//  OUT:  the browser's stage seam, window management, the typer, affordances,
//        the managed-UI executor, every probe
//  PIN:  A WINDOW, NOT A PROCESS. `NSRunningApplication.activate` asks the
//        system to make a process frontmost; it says nothing about whether any
//        window of it is on screen, and on a machine with a minimized window, a
//        window on another Space, or a helper process answering for the family,
//        "frontmost" was being reported about a person who could see nothing.
//        MEASURED, as "Chrome wouldn't come forward" for a Chrome that was
//        running, and as a browser reading its page frame from behind another
//        window. So the ladder here raises a window through Accessibility when
//        activation alone does not take, resolves a helper to the regular
//        process of its family, and proves a visible window by default.
//        ONE OWNER. Fourteen call sites had six sentences and two selection
//        rules for one condition; the reason an activation failed belongs to
//        this type, and callers speak `reason(app:)` rather than a sentence of
//        their own.
//

import AppKit
import ApplicationServices
import Foundation

/// What happened, and — when it did not work — what to say about it.
public struct Activation: Sendable, Equatable {

    public enum Road: Sendable, Equatable {
        /// Already frontmost and visible; nothing was moved. Not a no-op worth avoiding — a
        /// three-operation turn used to activate six times, every one a visible window.
        case alreadyForward
        /// `NSRunningApplication.activate(options: [.activateAllWindows])`.
        case cooperative
        /// Activation alone did not take; a window was restored and raised
        /// through Accessibility, and the activation asked for again.
        case raised
        /// Kept for the callers that name it. No Apple Event is sent any more —
        /// `NoAppleEventsTests` — and no activation reports this road.
        case appleEvents
    }

    public enum Failure: Sendable, Equatable {
        case notRunning
        /// Every road ran and the app never took the foreground.
        case refused
        /// Automation consent has not been granted. Kept for the callers that
        /// name it; no road here sends an Apple Event any more.
        case automationDenied
        case scriptFailed(String)
        /// The turn was cancelled mid-activation. Distinct from `refused`
        /// because the app may well have come forward.
        case cancelled
        /// Frontmost, but nothing of it is on screen — every window minimized
        /// and none would restore, or no window at all.
        case noVisibleWindow
        /// Another act holds the stage and did not yield in time.
        case stageHeld(String)
    }

    public let road: Road?
    public let failure: Failure?

    public init(road: Road?, failure: Failure?) {
        self.road = road
        self.failure = failure
    }

    public var succeeded: Bool { road != nil }

    static func won(_ road: Road) -> Activation { .init(road: road, failure: nil) }
    public static func lost(_ failure: Failure) -> Activation { .init(road: nil, failure: failure) }

    /// The same outcome in the monitor's named vocabulary.
    var monitorReason: ComputerUseRefusalReason? {
        switch failure {
        case .none: return nil
        case .notRunning: return .notRunning("that application")
        case .refused: return .activationRefused("that application")
        case .automationDenied: return .other("Automation consent not granted")
        case .scriptFailed(let detail): return .other(detail)
        case .cancelled: return .cancelled
        case .noVisibleWindow: return .other("frontmost, but nothing of it is on screen")
        case .stageHeld(let owner): return .other("the stage is held by \(owner)")
        }
    }

    /// A sentence for the user, or nil when it worked. Callers name the app;
    /// this names the cause.
    public func reason(app: String) -> String? {
        switch failure {
        case nil: return nil
        case .notRunning: return "\(app) isn't running."
        case .refused: return "\(app) didn't come to the foreground."
        case .automationDenied:
            return "Mary needs permission to control \(app). Allow it under Privacy & Security → Automation."
        case .scriptFailed(let detail): return "\(app) didn't come to the foreground — \(detail)"
        case .cancelled: return "Bringing \(app) forward was interrupted."
        case .noVisibleWindow:
            return "\(app) is in front, but none of its windows are on screen."
        case .stageHeld:
            return "Something else is using the screen right now — give me a moment and ask again."
        }
    }
}

public enum VerifiedActivation {

    /// How long activation alone is given before a window is raised for it.
    /// Cooperative activation that is going to take does so in well under this;
    /// what runs past it is the case the raise exists for.
    static let cooperativeShare: TimeInterval = 0.5
    /// The least the raise road is given, however little budget is left.
    static let raiseFloor: TimeInterval = 0.6

    /// Bring the app owning `pid` forward and PROVE it. `requireVisibleWindow`
    /// (the default) additionally proves a window is on screen — an app can be
    /// frontmost with nothing to look at, and a caller that is about to read
    /// pixels or type needs the window, not the process.
    ///
    /// REPORTS EITHER WAY — an activation that silently did not take is the
    /// failure this whole type exists to make visible.
    @discardableResult
    /// `raising` names the window the caller works in; the raise road restores
    /// and raises THAT one rather than whichever the application calls main.
    public static func bringForward(
        pid: pid_t,
        timeout: TimeInterval = 2.0,
        requireVisibleWindow: Bool = true,
        raising window: CGWindowID? = nil
    ) async -> Activation {
        let activation = await bringForwardCore(
            pid: pid, timeout: timeout, requireVisibleWindow: requireVisibleWindow,
            window: window)
        report(activation, pid: pid)
        return activation
    }

    private static func bringForwardCore(
        pid asked: pid_t,
        timeout: TimeInterval,
        requireVisibleWindow: Bool,
        window: CGWindowID? = nil
    ) async -> Activation {
        guard let process = NSRunningApplication(processIdentifier: asked),
              !process.isTerminated
        else { return .lost(.notRunning) }

        // A HELPER CANNOT COME FORWARD. A roster that matches a bundle family by
        // prefix hands over whichever process it met first, and a renderer or a
        // GPU helper answers to the family's prefix; activating one "succeeds"
        // and moves nothing. The regular member of the family is what is meant.
        let running = regularMember(of: process) ?? process
        let pid = running.processIdentifier

        // ALREADY THERE IS ALREADY DONE — unless nothing of it is on screen. A
        // hidden app is NOT already there: it can be frontmost with nothing
        // showing, which is why the unhide below exists at all. And a frontmost
        // app whose every window is minimized is the case a raise answers.
        // AND THE NAMED WINDOW HAS TO BE THE ONE IN FRONT. An application in
        // front with the wrong window forward is exactly the case that put a
        // round's chords into the person's own window (round 10): the
        // application was frontmost, so nothing was raised, and ⌘L went to
        // whichever of its windows was on top.
        if !running.isHidden, await isFrontmost(pid: pid),
           window == nil || isFrontWindow(window!, in: pid) {
            if !requireVisibleWindow || hasUnminimizedWindow(pid: pid) {
                return .won(.alreadyForward)
            }
            return await raise(
                running, within: max(raiseFloor, timeout / 2),
                requireVisibleWindow: requireVisibleWindow, window: window)
        }

        if running.isHidden { running.unhide() }
        // A NAMED WINDOW THAT IS NOT IN FRONT IS THE RAISE ROAD'S, from the
        // start. Cooperative activation orders nothing; measured, it "won"
        // with the person's window still on top, and the next keystrokes went
        // to their address bar.
        if let window, !isFrontWindow(window, in: pid) {
            return await raise(
                running, within: max(raiseFloor, timeout),
                requireVisibleWindow: requireVisibleWindow, window: window)
        }
        running.activate(options: window == nil ? [.activateAllWindows] : [])
        let cooperative = min(timeout, max(cooperativeShare, timeout * 0.4))
        switch await frontmost(pid: pid, within: cooperative) {
        case .arrived:
            return await settle(
                .cooperative, running: running, requireVisibleWindow: requireVisibleWindow,
                window: window)
        case .cancelled: return .lost(.cancelled)
        case .timedOut: break
        }

        // ESCALATE. Cooperative activation declines quietly when the asking
        // process is not itself in front, and never moves a window that is
        // minimized or on another Space. Raising a window through Accessibility
        // is the gesture a person makes when clicking the app did nothing.
        return await raise(
            running, within: max(raiseFloor, timeout - cooperative),
            requireVisibleWindow: requireVisibleWindow, window: window)
    }

    /// The raise road: restore and raise a window, ask for activation again,
    /// and wait the rest of the budget.
    private static func raise(
        _ running: NSRunningApplication,
        within budget: TimeInterval,
        requireVisibleWindow: Bool,
        window: CGWindowID? = nil
    ) async -> Activation {
        let pid = running.processIdentifier
        raiseAWindow(pid: pid, preferring: window)
        // THE ASSISTIVE ROAD. Cooperative activation is a REQUEST, and macOS
        // grants it to the active application; an application that is not
        // active — Mary, spoken to while the person works in an editor — is
        // ignored, and a raised window does not activate its process. MEASURED
        // from the bench, a regular application behind an editor: "Chrome
        // didn't come to the foreground" after the whole budget, while the
        // same call from a command-line probe succeeded. Setting the
        // application's own frontmost attribute is how an assistive client
        // activates what it is driving, and it is granted to a trusted process
        // whoever is active.
        setFrontmostThroughAccessibility(pid: pid)
        running.activate(options: window == nil ? [.activateAllWindows] : [])
        switch await frontmost(pid: pid, within: budget) {
        case .arrived:
            // A NAMED WINDOW HAS TO BE THE ONE IN FRONT, or the application
            // being in front is worth nothing: measured, a window restored from
            // the Dock came back BEHIND the person's, the application was
            // frontmost, and the next keystrokes went into their address bar.
            // AND SAID AGAIN AFTER THE ACTIVATION, which re-orders windows on
            // its own — with `activateAllWindows` it put the person's window
            // back in front of the one just raised, measured twice.
            if let window {
                raiseAWindow(pid: pid, preferring: window)
                try? await Task.sleep(for: .milliseconds(150))
                guard isFrontWindow(window, in: pid) else { return .lost(.refused) }
            }
            return await settle(.raised, running: running, requireVisibleWindow: requireVisibleWindow, window: window)
        case .cancelled: return .lost(.cancelled)
        case .timedOut: break
        }
        // One last read: a Space switch can land just past the deadline.
        guard await isFrontmost(pid: pid) else { return .lost(.refused) }
        if let window, !isFrontWindow(window, in: pid) { return .lost(.refused) }
        return await settle(.raised, running: running, requireVisibleWindow: requireVisibleWindow, window: window)
    }

    /// Bring the app with the EXACT `bundleID` forward and prove an app matching
    /// `matchPrefix` (default: the id itself) is frontmost.
    @discardableResult
    public static func bringForward(
        bundleID: String,
        matchPrefix: String? = nil,
        timeout: TimeInterval = 2.0,
        requireVisibleWindow: Bool = true
    ) async -> Activation {
        let activation = await bringForwardCore(
            bundleID: bundleID, matchPrefix: matchPrefix,
            timeout: timeout, requireVisibleWindow: requireVisibleWindow)
        report(activation, bundleID: bundleID)
        return activation
    }

    private static func bringForwardCore(
        bundleID: String,
        matchPrefix: String?,
        timeout: TimeInterval,
        requireVisibleWindow: Bool
    ) async -> Activation {
        let prefix = matchPrefix ?? bundleID
        guard let running = regularApplication(bundleID: bundleID, prefix: prefix) else {
            return .lost(.notRunning)
        }
        let outcome = await bringForward(
            pid: running.processIdentifier,
            timeout: timeout,
            requireVisibleWindow: requireVisibleWindow)
        // A SIBLING OF THE FAMILY COUNTS. We drove one exact process, but the
        // caller asked whether the family owns the foreground — and on a
        // machine running two builds the user's answer is yes.
        if outcome.succeeded || outcome.failure == .noVisibleWindow { return outcome }
        return await frontmostIsRegular(prefix: prefix) ? .won(.cooperative) : outcome
    }

    // MARK: - Process selection

    /// A REGULAR PROCESS OF THE FAMILY, never a background helper.
    static func regularApplication(bundleID: String, prefix: String) -> NSRunningApplication? {
        let regular = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
        if let exact = regular.first { return exact }
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated
                && $0.activationPolicy == .regular
                && $0.bundleIdentifier?.hasPrefix(prefix) == true
        }
    }

    /// The regular member of a helper's family, or nil when `process` is
    /// regular itself or nothing regular owns its bundle id.
    static func regularMember(of process: NSRunningApplication) -> NSRunningApplication? {
        guard process.activationPolicy != .regular, let helper = process.bundleIdentifier
        else { return nil }
        let regular = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }
        guard let family = familyBundleID(
            forHelper: helper, regular: regular.compactMap(\.bundleIdentifier))
        else { return nil }
        return regular.first { $0.bundleIdentifier == family }
    }

    /// Which regular bundle id a helper belongs to: the longest regular id the
    /// helper's id extends by a dotted component. Pure, so it can be measured.
    /// "com.google.Chrome.helper.renderer" → "com.google.Chrome";
    /// "com.example.Other" → nil.
    static func familyBundleID(forHelper helper: String, regular: [String]) -> String? {
        regular
            .filter { helper.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
    }

    // MARK: - Main-actor verification

    private enum Arrival { case arrived, timedOut, cancelled }

    /// Is this the process in front? The one frontmost read every stage seam
    /// shares, so no lane keeps a second copy.
    public static func isFrontmost(pid: pid_t) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
    }

    /// Is a regular application of this family in front? Family, because a
    /// beta and a stable build answer to one prefix and the person sees one app.
    public static func isFrontmost(prefix: String) async -> Bool {
        await frontmostIsRegular(prefix: prefix)
    }

    /// Who is in front right now, when it is a regular application and not
    /// Mary herself — the process an act should give the stage back to.
    public static func frontmostRegularApplication() async -> pid_t? {
        await MainActor.run {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.activationPolicy == .regular,
                  front.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return nil }
            return front.processIdentifier
        }
    }

    private static func frontmostIsRegular(prefix: String) async -> Bool {
        await MainActor.run {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.activationPolicy == .regular,
                  let id = front.bundleIdentifier
            else { return false }
            return id.hasPrefix(prefix)
        }
    }

    private static func frontmost(pid: pid_t, within seconds: TimeInterval) async -> Arrival {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await isFrontmost(pid: pid) { return .arrived }
            // THE FINAL READ COMES FIRST. Returning on cancellation without
            // looking once more reported "didn't come forward" for an app
            // that had.
            if Task.isCancelled {
                return await isFrontmost(pid: pid) ? .arrived : .cancelled
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await isFrontmost(pid: pid) ? .arrived : .timedOut
    }

    // MARK: - Windows

    /// Restore and raise THE window of the process — its main window, else the
    /// frontmost in its own order — so that a window minimized or on another
    /// Space comes to the person. Best effort: without Accessibility there is
    /// no window to address and the activation stands on its own.
    ///
    /// PIN: THE MAIN WINDOW, NOT ANY WINDOW THAT HAPPENS TO BE VISIBLE. A first
    /// rule preferred an unminimized window, and MEASURED on a browser with two:
    /// the person's other window came forward and the page that was asked
    /// about stayed in the Dock — the engine then read and hovered the wrong
    /// page. The application's own notion of its main window is the one the
    /// person last worked in, minimized or not.
    /// Whether the named window is the application's main (front) window.
    /// A window that is gone is not in front either.
    static func isFrontWindow(_ id: CGWindowID, in pid: pid_t) -> Bool {
        guard let window = AXWindowIdentity.window(id: id, in: pid) else { return false }
        return AXWindowRoster.copyBool(window, kAXMainAttribute) == true
            && AXWindowRoster.copyBool(window, kAXMinimizedAttribute) != true
    }

    /// THE WINDOW THE CALLER WORKS IN, when it names one — see
    /// `AXWindowIdentity`. The main window is what is raised for a caller
    /// that names none, and the first when nothing is main.
    private static func raiseAWindow(pid: pid_t, preferring wanted: CGWindowID? = nil) {
        guard AXIsProcessTrusted(),
              let windows = AXWindowRoster.axWindows(of: pid, standardOnly: true),
              let window = windows.first(where: {
                  wanted != nil && AXWindowIdentity.windowID(of: $0.element) == wanted
              }) ?? windows.first(where: {
                  AXWindowRoster.copyBool($0.element, kAXMainAttribute) == true
              }) ?? windows.first
        else { return }
        try? AccessibilityWindowCore.restore(window.element)
        try? AccessibilityWindowCore.raise(window.element, title: window.title)
        // AND MAIN, said outright: a raise alone left a restored window behind
        // the one the person last clicked.
        if wanted != nil {
            AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Ask the application, through Accessibility, to be frontmost. Checked;
    /// the caller verifies with the workspace read either way.
    @discardableResult
    static func setFrontmostThroughAccessibility(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        let set = AXUIElementSetAttributeValue(
            application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        ComputerUseMonitor.shared.note(
            lane: .stage, act: "setFrontmost", pid: pid,
            detail: set == .success ? "via Accessibility" : "refused (\(set.rawValue))")
        return set == .success
    }

    /// Frontmost proves ownership of the foreground; this proves there is
    /// something on screen. Without Accessibility we cannot ask, and we do NOT
    /// invent a failure: the activation itself was verified by other means.
    private static func settle(
        _ road: Activation.Road,
        running: NSRunningApplication,
        requireVisibleWindow: Bool,
        window: CGWindowID? = nil
    ) async -> Activation {
        let pid = running.processIdentifier
        // THE NAMED WINDOW IN FRONT, OR NOTHING WON — whichever road got here.
        if let window, AXIsProcessTrusted(), !isFrontWindow(window, in: pid) {
            raiseAWindow(pid: pid, preferring: window)
            guard isFrontWindow(window, in: pid) else { return .lost(.refused) }
        }
        guard requireVisibleWindow, AXIsProcessTrusted() else { return .won(road) }
        if hasUnminimizedWindow(pid: pid) { return .won(road) }
        // NOTHING ON SCREEN YET. Restore a window once before giving up on it —
        // a person whose every window is minimized clicks the Dock and gets one.
        raiseAWindow(pid: pid, preferring: window)
        return hasUnminimizedWindow(pid: pid) ? .won(.raised) : .lost(.noVisibleWindow)
    }

    private static func hasUnminimizedWindow(pid: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else {
            // No answer is not a denial. An app that exposes no window list
            // may still be perfectly usable; refusing here would invent the
            // very false negative this file exists to remove.
            return true
        }
        guard !windows.isEmpty else { return false }
        for window in windows {
            var minimized: CFTypeRef?
            let read = AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &minimized)
            if read != .success { return true }
            if (minimized as? Bool) != true { return true }
        }
        return false
    }

    // MARK: - Reporting

    private static func report(_ activation: Activation, pid: pid_t) {
        report(activation, target: "pid \(pid)", pid: pid)
    }

    private static func report(_ activation: Activation, bundleID: String) {
        report(activation, target: bundleID, pid: nil)
    }

    private static func report(_ activation: Activation, target: String, pid: pid_t?) {
        if let road = activation.road {
            ComputerUseMonitor.shared.note(
                lane: .stage, act: "bringForward", pid: pid,
                detail: "\(target) via \(road)")
        } else if let reason = activation.monitorReason {
            ComputerUseMonitor.shared.note(
                lane: .stage, refused: "bringForward", pid: pid, reason: reason)
        }
    }
}

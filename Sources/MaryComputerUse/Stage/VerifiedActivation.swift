//
//  VerifiedActivation.swift
//  MaryComputerUse
//
//  WHAT: Activate an app and prove the frontmost pid matches.
//  OUT:  looking / window / surface skills

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
        /// The Apple Events `activate` verb — the target activates ITSELF,
        /// which cooperative activation cannot refuse the same way.
        case appleEvents
    }

    public enum Failure: Sendable, Equatable {
        case notRunning
        /// Both roads ran and the app never took the foreground.
        case refused
        /// osascript could not talk to the app. `-1743` is the one worth
        /// naming: Automation consent has not been granted, which no amount
        /// of retrying will fix.
        case automationDenied
        case scriptFailed(String)
        /// The turn was cancelled mid-activation. Distinct from `refused`
        /// because the app may well have come forward.
        case cancelled
        /// Frontmost, but every window is minimized — the caller asked for a
        /// surface it could actually type into.
        case noVisibleWindow
    }

    public let road: Road?
    public let failure: Failure?

    public var succeeded: Bool { road != nil }

    static func won(_ road: Road) -> Activation { .init(road: road, failure: nil) }
    static func lost(_ failure: Failure) -> Activation { .init(road: nil, failure: failure) }

    /// The same outcome in the monitor's named vocabulary.
    var monitorReason: ComputerUseRefusalReason? {
        switch failure {
        case .none: return nil
        case .notRunning: return .notRunning("that application")
        case .refused: return .activationRefused("that application")
        case .automationDenied: return .other("Automation consent not granted")
        case .scriptFailed(let detail): return .other(detail)
        case .cancelled: return .cancelled
        case .noVisibleWindow: return .other("frontmost, but every window is minimized")
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
            return "\(app) is in front but all its windows are minimized."
        }
    }
}

public enum VerifiedActivation {

    /// Apple Events road gets its own short budget (3s), not the 30s scripting default.
    private static let appleEventsBudget: TimeInterval = 3.0

    /// Bring the app owning `pid` forward and PROVE it. `requireVisibleWindow` additionally
    /// proves a window is on screen.
    /// Bring `pid` forward, prove it, and REPORT either way — an activation
    /// that silently did not take is the failure this whole type exists to
    /// make visible.
    @discardableResult
    public static func bringForward(
        pid: pid_t,
        timeout: TimeInterval = 2.0,
        requireVisibleWindow: Bool = false
    ) async -> Activation {
        let activation = await bringForwardCore(
            pid: pid, timeout: timeout, requireVisibleWindow: requireVisibleWindow)
        report(activation, pid: pid)
        return activation
    }

    private static func bringForwardCore(
        pid: pid_t,
        timeout: TimeInterval = 2.0,
        requireVisibleWindow: Bool = false
    ) async -> Activation {
        guard let running = NSRunningApplication(processIdentifier: pid),
              !running.isTerminated
        else { return .lost(.notRunning) }

        // ALREADY THERE IS ALREADY DONE. A hidden app is NOT already there: it
        // can be frontmost with nothing on screen, which is why the unhide
        // below exists at all.
        if !running.isHidden, await isFrontmost(pid: pid) {
            return await settle(.alreadyForward, pid: pid, requireVisibleWindow: requireVisibleWindow)
        }
        // A hidden app does not come forward by being activated: ⌘H (or every
        // window minimized) leaves the request "successful" with nothing
        // moving on screen.
        if running.isHidden { running.unhide() }
        running.activate(options: [.activateAllWindows])
        switch await frontmost(pid: pid, within: timeout) {
        case .arrived:
            return await settle(.cooperative, pid: pid, requireVisibleWindow: requireVisibleWindow)
        case .cancelled: return .lost(.cancelled)
        case .timedOut: break
        }
        // No Apple Event `activate` fallback. NSWorkspace is the only road.

        // One last read: a Space switch can land just past the deadline.
        guard await isFrontmost(pid: pid) else { return .lost(.refused) }
        return await settle(.appleEvents, pid: pid, requireVisibleWindow: requireVisibleWindow)
    }

    /// Bring the app with the EXACT `bundleID` forward and prove an app matching
    /// `matchPrefix` (default: the id itself) is frontmost.
    @discardableResult
    public static func bringForward(
        bundleID: String,
        matchPrefix: String? = nil,
        timeout: TimeInterval = 2.0,
        requireVisibleWindow: Bool = false
    ) async -> Activation {
        let activation = await bringForwardCore(
            bundleID: bundleID, matchPrefix: matchPrefix,
            timeout: timeout, requireVisibleWindow: requireVisibleWindow)
        report(activation, bundleID: bundleID)
        return activation
    }

    private static func bringForwardCore(
        bundleID: String,
        matchPrefix: String? = nil,
        timeout: TimeInterval = 2.0,
        requireVisibleWindow: Bool = false
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
        return await frontmostIsRegular(prefix: prefix) ? .won(.appleEvents) : outcome
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

    // MARK: - Main-actor verification

    private enum Arrival { case arrived, timedOut, cancelled }

    private static func isFrontmost(pid: pid_t) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
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

    // MARK: - Visibility

    /// Frontmost proves ownership of the foreground; this proves there is
    /// something on screen. Without Accessibility we cannot ask, and we do NOT
    /// invent a failure: the activation itself was verified by other means.
    private static func settle(
        _ road: Activation.Road,
        pid: pid_t,
        requireVisibleWindow: Bool
    ) async -> Activation {
        guard requireVisibleWindow, AXIsProcessTrusted() else { return .won(road) }
        return hasUnminimizedWindow(pid: pid) ? .won(road) : .lost(.noVisibleWindow)
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

    // MARK: - Apple Events diagnosis

    /// `-1743` is "not authorised to send Apple events", i.e. Automation
    /// consent. It is worth its own sentence because retrying never fixes it
    /// and the user has something specific to do.
    private static func scriptFailure(_ output: String) -> Activation.Failure? {
        guard !output.isEmpty else { return nil }
        if output.contains("-1743") || output.localizedCaseInsensitiveContains("not authori") {
            return .automationDenied
        }
        return nil
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

//
//  ComputerUseModels.swift
//  MaryComputerUse
//
//  WHAT: What the machine layer did, what it refused, and why.
//  IN:   every lane's report site
//  OUT:  ComputerUseMonitor snapshot + events
//  PIN:  A REFUSAL IS NAMED, NEVER A BARE FALSE. The whole point of watching
//        this layer is that a skipped act says why it skipped. Nothing here
//        carries content — no typed text, no pixels, no subprocess output.
//

import Foundation

/// Which instrument acted. One case per directory under Hands/, plus the
/// reading lanes and the process lane.
public enum ComputerUseLane: String, Sendable, Codable, CaseIterable {
    case accessibility
    case sight
    case keyboard
    case pointer
    case elements
    case windows
    case menus
    case mediaKeys
    case stage
    case process
}

/// Why an act did not happen. Named, because "it returned false" is what this
/// type exists to stop being the answer.
public enum ComputerUseRefusalReason: Sendable, Codable, Equatable {
    /// The Accessibility grant is missing — the one that looks enabled in
    /// System Settings after an ad-hoc rebuild and quietly is not.
    case accessibilityUntrusted
    case screenRecordingUnavailable(String)
    case eventNotCreated
    /// The key has no keycode on this layout.
    case noKeyCode(String)
    case noFocusedWindow
    case noCapturedSpace(String)
    case anchorNotUnique
    case elementHasNoFrame
    case pressRefused(String)
    case itemDisabled(String)
    case menuLevelMissing(String)
    case notRunning(String)
    case activationRefused(String)
    case targetLostFocus(String?)
    /// The vision engine could not be created or a lane failed inside it.
    case visionUnavailable(String)
    /// The region classifier is not on this machine — a configuration, not a fault.
    /// The media lane never asks for it; the element lane cannot proceed without it.
    case classifierUnavailable
    /// Nothing to read pixels from: no window on screen, or the page has no frame.
    case pageNotVisible
    /// No transport was found at all. The controls are usually hidden, not absent.
    case mediaControlsNotFound
    /// A transport was found but not the control the act needed.
    case mediaControlNotFound(String)
    /// The act landed and the state did not move — the receipt that failed.
    case mediaStateUnchanged(String)
    case cancelled
    case processLaunchFailed(String)
    case processTimedOut(seconds: Double)
    case other(String)

    /// One line, for a watcher and for the log mirror.
    public var summary: String {
        switch self {
        case .accessibilityUntrusted:
            return "Accessibility is not granted to this binary"
        case .screenRecordingUnavailable(let detail):
            return "screen recording unavailable: \(detail)"
        case .eventNotCreated: return "the event could not be created"
        case .noKeyCode(let key): return "no keycode for \(key) on this layout"
        case .noFocusedWindow: return "no focused window"
        case .noCapturedSpace(let name): return "no captured region named \(name)"
        case .anchorNotUnique: return "the locator matched no single control"
        case .elementHasNoFrame: return "the element has no usable frame"
        case .pressRefused(let what): return "press refused: \(what)"
        case .itemDisabled(let item): return "\(item) is disabled"
        case .menuLevelMissing(let level): return "no menu level named \(level)"
        case .notRunning(let app): return "\(app) is not running"
        case .activationRefused(let app): return "\(app) did not come forward"
        case .targetLostFocus(let now): return "target lost focus (frontmost: \(now ?? "none"))"
        case .visionUnavailable(let detail): return "vision unavailable: \(detail)"
        case .classifierUnavailable: return "no region classifier is installed"
        case .pageNotVisible: return "the page is not visible to capture"
        case .mediaControlsNotFound: return "no media transport was found"
        case .mediaControlNotFound(let what): return "no \(what) control in the transport"
        case .mediaStateUnchanged(let what): return "\(what) did not change"
        case .cancelled: return "cancelled"
        case .processLaunchFailed(let tool): return "could not launch \(tool)"
        case .processTimedOut(let seconds): return "timed out after \(seconds)s"
        case .other(let detail): return detail
        }
    }
}

/// One thing the machine layer actually did.
public struct ComputerUseAct: Sendable, Equatable, Codable {
    /// Monotonic. A watcher that sees a gap knows it dropped events rather
    /// than that nothing happened.
    public let sequence: UInt64
    public let at: Date
    public let lane: ComputerUseLane
    /// The verb: "keyChord", "click", "raise", "processStart".
    public let name: String
    public let pid: pid_t?
    /// Shape, never content — "27 characters", not the characters.
    public let detail: String

    public init(
        sequence: UInt64, at: Date, lane: ComputerUseLane,
        name: String, pid: pid_t? = nil, detail: String = ""
    ) {
        self.sequence = sequence; self.at = at; self.lane = lane
        self.name = name; self.pid = pid; self.detail = detail
    }
}

/// One thing the machine layer declined to do, and why.
public struct ComputerUseRefusal: Sendable, Equatable, Codable {
    public let sequence: UInt64
    public let at: Date
    public let lane: ComputerUseLane
    public let name: String
    public let pid: pid_t?
    public let reason: ComputerUseRefusalReason

    public init(
        sequence: UInt64, at: Date, lane: ComputerUseLane,
        name: String, pid: pid_t? = nil, reason: ComputerUseRefusalReason
    ) {
        self.sequence = sequence; self.at = at; self.lane = lane
        self.name = name; self.pid = pid; self.reason = reason
    }
}

/// What a watcher receives.
public enum ComputerUseEvent: Sendable, Equatable {
    case act(ComputerUseAct)
    case refusal(ComputerUseRefusal)
    /// Replayed once, immediately, to a new subscriber — so a watcher that
    /// attaches late still knows the state it attached to.
    case snapshot(ComputerUseSnapshot)
}

/// Per-lane running totals.
public struct ComputerUseLaneTally: Sendable, Equatable, Codable {
    public var acts: Int = 0
    public var refusals: Int = 0
    public var lastAct: ComputerUseAct?
    public var lastRefusal: ComputerUseRefusal?

    public init() {}
}

/// What one walk of an accessibility tree cost. Counted, never streamed: the
/// ambient poll runs about every 1.5 seconds and an event per walk would
/// drown everything a person is actually watching for.
public struct ComputerUseSenseTally: Sendable, Equatable, Codable {
    public var walks: Int = 0
    public var totalNodes: Int = 0
    public var lastNodes: Int = 0
    public var lastDuration: TimeInterval = 0
    public var truncatedWalks: Int = 0

    public init() {}
}

/// Everything the machine layer knows about itself right now.
public struct ComputerUseSnapshot: Sendable, Equatable, Codable {
    public var startedAt: Date
    public var accessibilityTrusted: Bool
    public var screenRecordingGranted: Bool
    public var lanes: [ComputerUseLane: ComputerUseLaneTally]
    /// The most recent refusal anywhere — usually the answer to "why did
    /// nothing happen just now".
    public var lastRefusal: ComputerUseRefusal?
    public var sense: ComputerUseSenseTally
    /// The tail, newest last.
    public var recentActs: [ComputerUseAct]
    public var recentRefusals: [ComputerUseRefusal]

    public init(
        startedAt: Date,
        accessibilityTrusted: Bool,
        screenRecordingGranted: Bool,
        lanes: [ComputerUseLane: ComputerUseLaneTally],
        lastRefusal: ComputerUseRefusal?,
        sense: ComputerUseSenseTally,
        recentActs: [ComputerUseAct],
        recentRefusals: [ComputerUseRefusal]
    ) {
        self.startedAt = startedAt
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingGranted = screenRecordingGranted
        self.lanes = lanes
        self.lastRefusal = lastRefusal
        self.sense = sense
        self.recentActs = recentActs
        self.recentRefusals = recentRefusals
    }

    public var totalActs: Int { lanes.values.reduce(0) { $0 + $1.acts } }
    public var totalRefusals: Int { lanes.values.reduce(0) { $0 + $1.refusals } }
}

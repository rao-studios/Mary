//
//  AmbientSurface.swift
//  MaryBrain
//
//  WHAT: TIER 0 — what is actually on screen for one application family, as AX saw it.
//  IN:   AmbientBridge.surface(from:place:) (plugin layer; this package never names the engine)
//  OUT:  AmbientContextStore+Surface → prompt (surfaceLine)
//  PIN:  Drops at expiry, never degrades. Provenance is live AX.
//

import Foundation

/// What is on screen for one family, right now.
public struct AmbientSurface: Sendable, Equatable {

    /// The application whose screen this is. `pid` is the process to return
    /// to; `bundleID` the identity ladder's input — both reported, neither
    /// user-visible prompt text.
    ///
    /// `CapturedApplication` (MaryFoundation/Behavior/AmbientCapture.swift) mirrors
    /// these fields for the persisted corpus, and stays separate: `pid` is
    /// non-optional here because a live surface always has one.
    public struct Application: Sendable, Equatable {
        public var name: String
        public var bundleID: String?
        public var pid: Int32

        public init(name: String, bundleID: String?, pid: Int32) {
            self.name = name
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    public struct Window: Sendable, Equatable {
        public var title: String
        public var frame: AXFrame?

        public init(title: String, frame: AXFrame? = nil) {
            self.title = title
            self.frame = frame
        }
    }

    /// One nameable thing the screen offers, in reading order.
    public struct Element: Sendable, Equatable {
        /// THE RE-FINDING KEY — `role.lowercased() + "|" + normalized(label)`, the same spelling
        /// the affordance lane and `AXElementRecord` use.
        public var identity: String
        public var ordinal: Int
        /// The raw AX role (`AXButton`) — kept for identity parity with the
        /// affordance lane, never rendered to a person.
        public var role: String
        /// The humanized word ("button"), derived by the bridge. A String
        /// because the kind vocabulary lives in the plugin layer.
        public var kind: String
        public var label: String
        public var frame: AXFrame?
        public var isFocused: Bool
        public var isEnabled: Bool
        public var containerTrail: [String]
        /// Nil today — the walked diet carries no help text; the seam exists
        /// so a future detail-lane enrichment lands without a shape change.
        public var help: String?

        public init(
            identity: String, ordinal: Int, role: String, kind: String, label: String,
            frame: AXFrame? = nil, isFocused: Bool = false, isEnabled: Bool = true,
            containerTrail: [String] = [], help: String? = nil
        ) {
            self.identity = identity
            self.ordinal = ordinal
            self.role = role
            self.kind = kind
            self.label = String(label.prefix(AmbientSurface.labelCap))
            self.frame = frame
            self.isFocused = isFocused
            self.isEnabled = isEnabled
            self.containerTrail = containerTrail
            self.help = help
        }

        /// How a person would name it — the label when it has one, the kind
        /// otherwise.
        public var descriptor: String { label.isEmpty ? kind : label }
    }

    /// The engine publishes at most 120 (its roster's own limit), restated
    /// here so the ambient side enforces its own bound.
    public static let elementCap = 120
    public static let labelCap = 120
    /// ~2.5× the observer's 10s active cadence: fresh means "within the
    /// last couple of polls".
    public static let defaultFreshFor: TimeInterval = 25

    /// The family lane this screen belongs to — attached by the bridge via
    /// the resolver, never by the engine.
    public var place: AmbientPlace
    public var application: Application
    /// Nil when no non-minimized window exists.
    public var activeWindow: Window?
    public var windowCount: Int
    public var minimizedCount: Int
    /// Reading order, capped at `elementCap`.
    public var elements: [Element]
    public var focused: Element?
    /// The target hosts web content whose tree has not been woken — the
    /// honest carrier of "I cannot see the page YET", which must never
    /// render as "the page is empty".
    public var pageNotYetRead: Bool
    public var capturedAt: Date
    public var freshFor: TimeInterval

    public init(
        place: AmbientPlace,
        application: Application,
        activeWindow: Window? = nil,
        windowCount: Int = 0,
        minimizedCount: Int = 0,
        elements: [Element] = [],
        focused: Element? = nil,
        pageNotYetRead: Bool = false,
        capturedAt: Date = Date(),
        freshFor: TimeInterval = AmbientSurface.defaultFreshFor
    ) {
        self.place = place
        self.application = application
        self.activeWindow = activeWindow
        self.windowCount = windowCount
        self.minimizedCount = minimizedCount
        self.elements = Array(elements.prefix(Self.elementCap))
        self.focused = focused
        self.pageNotYetRead = pageNotYetRead
        self.capturedAt = capturedAt
        self.freshFor = freshFor
    }

    public func age(at now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(capturedAt))
    }

    /// May this surface still claim to be the screen as it stands? Past this it is DROPPED, not degraded.
    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= freshFor
    }
}

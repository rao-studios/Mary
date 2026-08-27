//
//  AmbientSurface.swift
//  MaryBrain
//
//  THE TIER-0 RECORD: what is actually on screen for one application family,
//  as the accessibility engine saw it — the FOUNDATION the store's fact tier
//  supports with details. `AmbientFact` is one processed sensory detail;
//  this is the ground those details stand on: the app, its active window,
//  the nameable things it offers in reading order, and where focus sits.
//
//  IT ARRIVES FROM OUTSIDE. MaryAmbient never names the engine that
//  produced it (the layering rule `PackageLayeringTests` pins); the plugin
//  layer's `AmbientBridge.surface(from:place:)` renders the engine's
//  artifact into this vocabulary, exactly as each watcher world renders its
//  own snapshot into facts.
//
//  PROVENANCE IS IMPLICITLY LIVE-AX — the tier exists BECAUSE it is the
//  live accessibility read. That is also why a surface DROPS at expiry
//  rather than degrading with an age the way facts do: a stale fact is
//  held knowledge, a stale screen is a confidently wrong screen.
//
//  GEOMETRY IS `AXFrame`, NOT `CGRect` — precise, self-describing screen
//  position (`MaryFoundation/Core/AXFrame.swift`), the core precision
//  element in how Mary knows WHERE something is. `AXFrame` carries no
//  CoreGraphics itself; the plugin layer's `AXFrameProjection` is where a
//  live `CGRect` becomes one, exactly as `AmbientBridge.surface(from:place:)`
//  is where the engine's artifact becomes this vocabulary. A frame is
//  evidence of a moment (it is capture-stamped), never a target to press
//  blind — every actuation path still re-reads and re-locates by identity
//  before touching anything.
//

import Foundation

/// What is on screen for one family, right now.
public struct AmbientSurface: Sendable, Equatable {

    /// The application whose screen this is. `pid` is the process to return
    /// to; `bundleID` the identity ladder's input — both reported, neither
    /// user-visible prompt text.
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
        /// THE RE-FINDING KEY — `role.lowercased() + "|" + normalized(label)`,
        /// the same spelling the affordance lane and `AXElementRecord` use.
        ///
        /// The ordinal below is a POSITION and re-flows the moment a window
        /// re-lays out; this survives it. Bonnie computed this identity in the
        /// bridge and threw it away on the surface side, so a captured element
        /// and a live re-read had no common key — which is precisely what the
        /// behavioural capture needs to line up an element it recorded with the
        /// one an action later touched.
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

    /// May this surface still claim to be the screen as it stands? Past
    /// this it is DROPPED, not degraded — see the header.
    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= freshFor
    }
}

//
//  AXAmbientContext.swift
//  MaryAdapter
//
//  WHAT: One-shot ambient artifact — identity, front window, roster, focus.
//  IN:   AXAppSnapshot (pure derive)
//  OUT:  AmbientBridge.surface | AXAmbientPresentation
//  PIN:  bundleID reported, never branched. Silence ≠ absence. == skips timing.

import CoreGraphics
import Foundation

/// The engine's ambient artifact: what it sees for one app, right now.
public struct AXAmbientContext: Sendable, Equatable {

    /// Who was walked. Reported, never branched on.
    public struct AppIdentity: Sendable, Equatable {
        public var pid: pid_t
        public var bundleID: String?
        public var appName: String

        public init(pid: pid_t, bundleID: String?, appName: String) {
            self.pid = pid
            self.bundleID = bundleID
            self.appName = appName
        }
    }

    /// The active window — `AXElementRoster.WindowScope.front` semantics:
    /// the first non-minimized window in the snapshot's own front-to-back
    /// order, reused not respelled.
    public struct WindowSummary: Sendable, Equatable {
        public var id: AXNodeID
        public var title: String
        public var frame: CGRect?
        public var isMain: Bool
        public var isTruncated: Bool

        public init(
            id: AXNodeID, title: String, frame: CGRect?,
            isMain: Bool, isTruncated: Bool
        ) {
            self.id = id
            self.title = title
            self.frame = frame
            self.isMain = isMain
            self.isTruncated = isTruncated
        }
    }

    /// The node claiming keyboard focus, when one does. Honest nil — the
    /// label is whatever the walk recorded, never invented.
    public struct FocusedElement: Sendable, Equatable {
        public var id: AXNodeID
        public var role: String
        public var label: String?
        /// Nil when the node declined to answer a frame — `AXNodeSnapshot`'s own
        /// convention.
        public var frame: CGRect?

        public init(id: AXNodeID, role: String, label: String?, frame: CGRect? = nil) {
            self.id = id
            self.role = role
            self.label = label
            self.frame = frame
        }
    }

    // No web or scripting lane here. Those return with their engines.

    /// What the derivation cost and how complete it is. `==` deliberately
    /// ignores `capturedAt`/`walkDuration` — see the header.
    public struct Capture: Sendable, Equatable {
        public var capturedAt: Date
        public var walkDuration: Duration
        public var nodeCount: Int
        public var isTruncated: Bool
        /// AX-notification coverage, folded from the streamer's
        /// per-notification dictionary. Nil on a one-shot walk, which has no
        /// observers at all — a distinct claim from "0 of 0 covered".
        public var observersCovered: Int?
        public var observersTotal: Int?

        public init(
            capturedAt: Date, walkDuration: Duration,
            nodeCount: Int, isTruncated: Bool,
            observersCovered: Int? = nil, observersTotal: Int? = nil
        ) {
            self.capturedAt = capturedAt
            self.walkDuration = walkDuration
            self.nodeCount = nodeCount
            self.isTruncated = isTruncated
            self.observersCovered = observersCovered
            self.observersTotal = observersTotal
        }

        public static func == (lhs: Capture, rhs: Capture) -> Bool {
            lhs.nodeCount == rhs.nodeCount
                && lhs.isTruncated == rhs.isTruncated
                && lhs.observersCovered == rhs.observersCovered
                && lhs.observersTotal == rhs.observersTotal
        }
    }

    /// Scope the ambient tier publishes. `.all` = on screen, not only actionable.
    public static let ambientScope = AXElementRoster.Scope.all

    public var app: AppIdentity
    /// Nil when no non-minimized window exists.
    public var activeWindow: WindowSummary?
    public var windowCount: Int
    public var minimizedCount: Int
    /// Reading-order roster of the ACTIVE window — `AXElementRoster.elements`
    /// verbatim, scope recorded so a consumer knows what the list claims.
    public var elements: [AXScreenElement]
    public var scope: AXElementRoster.Scope
    public var focused: FocusedElement?
    /// This process hosts web content — see the note at the derivation site.
    public var webContentHost: Bool
    public var capture: Capture

    // MARK: - Derivation (pure)

    /// The one derivation there is. `observersCovered`/`observersTotal`
    /// describe live-observer coverage and stay nil on a one-shot walk, which
    /// is every walk in this build.
    public init(
        snapshot: AXAppSnapshot,
        scope: AXElementRoster.Scope = AXAmbientContext.ambientScope,
        limit: Int = AXElementRoster.publishedLimit,
        webContentHost: Bool = false,
        observersCovered: Int? = nil,
        observersTotal: Int? = nil
    ) {
        self.webContentHost = webContentHost
        self.app = AppIdentity(
            pid: snapshot.pid, bundleID: snapshot.bundleID, appName: snapshot.appName)
        let front = snapshot.windows.first { !$0.isMinimized }
        self.activeWindow = front.map {
            WindowSummary(
                id: $0.id, title: $0.title, frame: $0.frame,
                isMain: $0.isMain, isTruncated: $0.isTruncated)
        }
        self.windowCount = snapshot.windows.count
        self.minimizedCount = snapshot.windows.filter(\.isMinimized).count
        self.elements = AXElementRoster.elements(
            in: snapshot, scope: scope, windows: .front, limit: limit)
        self.scope = scope
        self.focused = Self.focusedElement(in: snapshot)
        self.capture = Capture(
            capturedAt: snapshot.capturedAt,
            walkDuration: snapshot.walkDuration,
            nodeCount: snapshot.nodeCount,
            isTruncated: snapshot.windows.contains(where: \.isTruncated),
            observersCovered: observersCovered,
            observersTotal: observersTotal)
    }

    /// First node claiming focus, searched front-to-back across the non-minimized windows —
    /// the active window first, then the rest, because AX focus can legitimately sit. Nil
    /// when nothing claims it.
    static func focusedElement(in snapshot: AXAppSnapshot) -> FocusedElement? {
        for window in snapshot.windows where !window.isMinimized {
            guard let root = window.root else { continue }
            var found: FocusedElement?
            root.forEachNode { node in
                guard found == nil, node.isFocused else { return }
                found = FocusedElement(
                    id: node.id, role: node.role, label: node.label, frame: node.frame)
            }
            if let found { return found }
        }
        return nil
    }
}

//
//  AXFrame.swift
//  MaryFoundation
//
//  WHAT: Named-space screen geometry. Evidence for a moment, never identity.
//  IN:   MaryPlugin/AXEngine/AXFrameProjection (CGRect ↔ these Doubles).
//  OUT:  AXElementRecord, AmbientCapture, BehavioralAction.
//  PIN:  Synthesized Codable (observed, not `.mary` digest). No CG import;
//        math stays in AXFrameProjection. Re-find by identity, not this rect.
//

import Foundation

/// Coordinate space of the numbers. Named so a later space cannot be misread as this one.
public enum AXFrameSpace: String, Codable, Hashable, Sendable {
    case axGlobalTopLeft
}

/// Rectangle in the carrying `AXFrame`'s space. Four Doubles — no `CGRect` here.
public struct AXFrameRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Point in the carrying frame's space.
public struct AXFramePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Display roster index + that display's bounds. No live `NSScreen` required.
public struct AXFrameScreen: Codable, Hashable, Sendable {
    /// Roster index this capture. Not a stable hardware id.
    public var index: Int
    public var rect: AXFrameRect

    public init(index: Int, rect: AXFrameRect) {
        self.index = index
        self.rect = rect
    }
}

/// One walked element's geometry at `capturedAt`.
public struct AXFrame: Codable, Hashable, Sendable {
    public var space: AXFrameSpace
    /// Reported rect; clipped to window when the producer clips (`isClipped`).
    public var rect: AXFrameRect
    /// Click target from AXFrameProjection — consumers do not re-derive mid.
    public var center: AXFramePoint
    /// Rect relative to window origin. Nil for a window-level frame.
    public var inWindow: AXFrameRect?
    /// Nil = no roster consulted, not "off-screen".
    public var screen: AXFrameScreen?
    /// Producer already clipped to the window.
    public var isClipped: Bool
    /// Moment of evidence. Re-locate by identity before actuating.
    public var capturedAt: Date

    public init(
        space: AXFrameSpace,
        rect: AXFrameRect,
        center: AXFramePoint,
        inWindow: AXFrameRect? = nil,
        screen: AXFrameScreen? = nil,
        isClipped: Bool = false,
        capturedAt: Date
    ) {
        self.space = space
        self.rect = rect
        self.center = center
        self.inWindow = inWindow
        self.screen = screen
        self.isClipped = isClipped
        self.capturedAt = capturedAt
    }
}

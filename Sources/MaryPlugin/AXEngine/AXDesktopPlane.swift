//
//  AXDesktopPlane.swift
//  MaryAdapter
//
//  WHAT: The one Cocoa→AX coordinate flip (NSScreen bottom-left → AX top-left).
//  IN:   NSScreen.frames (primary first) + primary height
//  OUT:  fit / viewRect / axPoint — scale+translate only after this
//  PIN:  ScreenRegionCapture and AXFrameProjection never flip; they stay in CG.

import CoreGraphics
import Foundation

public struct AXDesktopPlane: Sendable, Equatable {

    /// The union of every screen, in AX space — the coordinate frame Clyde's
    /// stage draws in.
    public let desktopBounds: CGRect
    /// Each screen's own bounds, in AX space, for the stage's faint screen
    /// outlines.
    public let screenBounds: [CGRect]

    /// - cocoaScreenFrames: `NSScreen.screens.map(\.frame)`, in Cocoa's bottom-left-origin
    /// space, PRIMARY SCREEN FIRST (AppKit's own convention.
    public init(cocoaScreenFrames: [CGRect], primaryScreenHeight: CGFloat) {
        let axFrames = cocoaScreenFrames.map { cocoa -> CGRect in
            // AX's y increases downward from the primary screen's top; Cocoa's
            // y increases upward from the primary screen's bottom. A screen's
            // AX-space top is therefore `primaryHeight - cocoaFrame.maxY`.
            let axY = primaryScreenHeight - cocoa.maxY
            return CGRect(x: cocoa.minX, y: axY, width: cocoa.width, height: cocoa.height)
        }
        self.screenBounds = axFrames
        self.desktopBounds = axFrames.reduce(into: CGRect.null) { $0 = $0.union($1) }
    }

    /// Empty-desktop fallback (no `NSScreen.screens`, or off the main
    /// thread before the first read) — a 1×1 plane that still lets callers
    /// compute a degenerate but crash-free transform.
    public static let empty = AXDesktopPlane(
        cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 1, height: 1)],
        primaryScreenHeight: 1)

    /// Scale + offset that fits `desktopBounds` inside `viewSize`, preserving
    /// aspect ratio and letterboxing the shorter axis — the transform every
    /// `viewRect(for:in:)` call applies.
    public func fit(into viewSize: CGSize) -> (scale: CGFloat, offset: CGPoint) {
        guard desktopBounds.width > 0, desktopBounds.height > 0,
              viewSize.width > 0, viewSize.height > 0
        else { return (1, .zero) }
        let scale = min(
            viewSize.width / desktopBounds.width,
            viewSize.height / desktopBounds.height)
        let scaledWidth = desktopBounds.width * scale
        let scaledHeight = desktopBounds.height * scale
        let offset = CGPoint(
            x: (viewSize.width - scaledWidth) / 2 - desktopBounds.minX * scale,
            y: (viewSize.height - scaledHeight) / 2 - desktopBounds.minY * scale)
        return (scale, offset)
    }

    /// Map one AX-space rect into view-space, given the view's current size.
    /// Both spaces are y-down after `init`'s one flip, so this is scale +
    /// translate only.
    public func viewRect(for axRect: CGRect, in viewSize: CGSize) -> CGRect {
        let (scale, offset) = fit(into: viewSize)
        return CGRect(
            x: axRect.minX * scale + offset.x,
            y: axRect.minY * scale + offset.y,
            width: axRect.width * scale,
            height: axRect.height * scale)
    }

    /// The inverse of `viewRect(for:in:)` — a point in the VIEW back to AX space.
    public func axPoint(for viewPoint: CGPoint, in viewSize: CGSize) -> CGPoint {
        let (scale, offset) = fit(into: viewSize)
        guard scale > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - offset.x) / scale, y: (viewPoint.y - offset.y) / scale)
    }

    /// A plane FOCUSED on one AX-space rect instead of the whole desktop — `screenBounds`
    /// rides along unchanged (so screen outlines still draw, even if.
    public func focused(on rect: CGRect) -> AXDesktopPlane {
        AXDesktopPlane(desktopBounds: rect, screenBounds: screenBounds)
    }

    /// The direct constructor `focused(on:)` uses. Not the primary entry point (Clyde
    /// always starts from `init(cocoaScreenFrames:...)`, the one real coordinate flip).
    public init(desktopBounds: CGRect, screenBounds: [CGRect]) {
        self.desktopBounds = desktopBounds
        self.screenBounds = screenBounds
    }
}

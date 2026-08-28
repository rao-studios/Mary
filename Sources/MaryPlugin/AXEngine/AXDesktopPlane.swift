//
//  AXDesktopPlane.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  THE ONE COORDINATE FLIP. AX reports frames in a GLOBAL, TOP-LEFT-ORIGIN
//  space (origin at the top-left of the PRIMARY screen, y increasing
//  downward) — the same convention CoreGraphics' display space uses
//  (`CGDisplayBounds`, and therefore `ScreenRegionCapture`/`AXFrameProjection`,
//  need no flip at all — they never touch `NSScreen`). `NSScreen.frame` is
//  Cocoa's space instead: origin at the primary screen's BOTTOM-left, y
//  increasing upward, and a screen above/left/right of the primary reported
//  in that same bottom-up frame. This is the ONE place in the repo that
//  needs the flip, because it is the one place Cocoa's `NSScreen` enters at
//  all (`init(cocoaScreenFrames:primaryScreenHeight:)`); everything
//  downstream — `fit(into:)`, `viewRect(for:in:)` — is scale and translate
//  only, no further sign flips.
//
//  Pure geometry, no AppKit types in the math path, so the flip and the
//  multi-display layout it produces are unit-testable without a real screen
//  (see AXDesktopPlaneTests).
//

import CoreGraphics
import Foundation

public struct AXDesktopPlane: Sendable, Equatable {

    /// The union of every screen, in AX space — the coordinate frame Clyde's
    /// stage draws in.
    public let desktopBounds: CGRect
    /// Each screen's own bounds, in AX space, for the stage's faint screen
    /// outlines.
    public let screenBounds: [CGRect]

    /// - Parameters:
    ///   - cocoaScreenFrames: `NSScreen.screens.map(\.frame)`, in Cocoa's
    ///     bottom-left-origin space, PRIMARY SCREEN FIRST (AppKit's own
    ///     convention — `NSScreen.screens[0]` is always the primary/menu-bar
    ///     screen).
    ///   - primaryScreenHeight: the primary screen's frame height — needed to
    ///     anchor the flip before secondary-screen frames (which may extend
    ///     above or below the primary) are converted against it.
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

    /// The inverse of `viewRect(for:in:)` — a point in the VIEW back to AX
    /// space. One consumer: resolving a click into "which element is here"
    /// (`AXHitTest`), which needs the tap converted into the same space
    /// every node's `frame` is already in.
    public func axPoint(for viewPoint: CGPoint, in viewSize: CGSize) -> CGPoint {
        let (scale, offset) = fit(into: viewSize)
        guard scale > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - offset.x) / scale, y: (viewPoint.y - offset.y) / scale)
    }

    /// A plane FOCUSED on one AX-space rect instead of the whole desktop —
    /// `screenBounds` rides along unchanged (so screen outlines still draw,
    /// even if they end up off-canvas once zoomed well inside one window),
    /// only `desktopBounds`, and therefore every `fit`/`viewRect`/`axPoint`
    /// call downstream of it, changes. This is the whole mechanism a
    /// click-to-zoom stage needs: "draw as if this rect were the desktop."
    public func focused(on rect: CGRect) -> AXDesktopPlane {
        AXDesktopPlane(desktopBounds: rect, screenBounds: screenBounds)
    }

    /// The direct constructor `focused(on:)` uses. Not the primary entry
    /// point (Clyde always starts from `init(cocoaScreenFrames:...)`, the
    /// one real coordinate flip) — this is for building a DERIVED plane from
    /// values already in AX space, and for tests that want a plane without
    /// touching `NSScreen`.
    public init(desktopBounds: CGRect, screenBounds: [CGRect]) {
        self.desktopBounds = desktopBounds
        self.screenBounds = screenBounds
    }
}

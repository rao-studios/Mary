//
//  AXDesktopPlaneTests.swift
//  BonniePluginTests
//
//  Pins the Cocoa (bottom-left-origin) → AX (top-left-origin) flip and the
//  multi-display union/fit math — pure geometry, no NSScreen needed.
//

import XCTest
@testable import MaryPlugin

final class AXDesktopPlaneTests: XCTestCase {

    // MARK: - The one flip

    func testPrimaryScreenTopLeftBecomesAXOrigin() {
        // A 1920×1080 primary screen in Cocoa space: origin at its own
        // bottom-left, so its frame is (0,0)-(1920,1080). In AX space its
        // top-left corner must land at (0,0).
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let plane = AXDesktopPlane(cocoaScreenFrames: [primary], primaryScreenHeight: 1080)
        XCTAssertEqual(plane.screenBounds.first, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testSecondaryScreenAboveThePrimaryLandsAtNegativeAXY() {
        // A secondary screen placed ABOVE the primary in Cocoa space (higher
        // y) must land at NEGATIVE y in AX space — AX extends upward off
        // the primary's top as negative, same convention CGDisplay space uses.
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let plane = AXDesktopPlane(cocoaScreenFrames: [primary, above], primaryScreenHeight: 1080)
        XCTAssertEqual(plane.screenBounds[0], CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(plane.screenBounds[1], CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    func testSecondaryScreenToTheRightKeepsItsXAndFlipsOnlyY() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let rightOfPrimary = CGRect(x: 1920, y: 0, width: 1280, height: 800)
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [primary, rightOfPrimary], primaryScreenHeight: 1080)
        // Same height as primary → same AX y (0); height differs from
        // primary, so its AX top is primaryHeight - cocoaMaxY = 1080-800=280.
        XCTAssertEqual(plane.screenBounds[1], CGRect(x: 1920, y: 280, width: 1280, height: 800))
    }

    // MARK: - Union bounds

    func testDesktopBoundsUnionsEveryScreen() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let plane = AXDesktopPlane(cocoaScreenFrames: [primary, above], primaryScreenHeight: 1080)
        XCTAssertEqual(plane.desktopBounds, CGRect(x: 0, y: -1080, width: 1920, height: 2160))
    }

    // MARK: - fit(into:) and viewRect(for:in:)

    func testFitLetterboxesTheShorterAxis() {
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 500)],
            primaryScreenHeight: 500)
        // Desktop is 2:1; a square view must scale to the width (the
        // constraining axis) and letterbox vertically.
        let (scale, offset) = plane.fit(into: CGSize(width: 500, height: 500))
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(offset.y, 125, accuracy: 0.0001)
    }

    func testViewRectRoundTripsAKnownRect() {
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 1000)],
            primaryScreenHeight: 1000)
        let viewSize = CGSize(width: 500, height: 500)
        let axRect = CGRect(x: 100, y: 200, width: 50, height: 50)
        let viewRect = plane.viewRect(for: axRect, in: viewSize)
        // Scale is 0.5 (1000 AX units → 500 view points), no letterboxing
        // (square desktop, square view).
        XCTAssertEqual(viewRect, CGRect(x: 50, y: 100, width: 25, height: 25))
    }

    func testDegenerateViewSizeDoesNotCrash() {
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 1000)],
            primaryScreenHeight: 1000)
        let (scale, offset) = plane.fit(into: .zero)
        XCTAssertEqual(scale, 1)
        XCTAssertEqual(offset, .zero)
    }

    // MARK: - axPoint(for:in:) — the inverse of viewRect, for hit testing

    func testAXPointInvertsViewRectForACenterPoint() {
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 1000)],
            primaryScreenHeight: 1000)
        let viewSize = CGSize(width: 500, height: 500)
        let axRect = CGRect(x: 100, y: 200, width: 50, height: 50)
        let viewRect = plane.viewRect(for: axRect, in: viewSize)
        let center = CGPoint(x: viewRect.midX, y: viewRect.midY)
        let recovered = plane.axPoint(for: center, in: viewSize)
        XCTAssertEqual(recovered.x, axRect.midX, accuracy: 0.001)
        XCTAssertEqual(recovered.y, axRect.midY, accuracy: 0.001)
    }

    func testAXPointHonoursLetterboxOffset() {
        // 2:1 desktop in a square view — the same letterboxed case
        // `testFitLetterboxesTheShorterAxis` pins, checked from the other
        // direction: a view point in the top letterbox band must map to an
        // AX y ABOVE the desktop (negative), not get clamped into it.
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 500)],
            primaryScreenHeight: 500)
        let point = plane.axPoint(for: CGPoint(x: 0, y: 0), in: CGSize(width: 500, height: 500))
        XCTAssertEqual(point.y, -250, accuracy: 0.001, "the 125pt letterbox band, unscaled")
    }

    func testAXPointOnADegeneratePlaneDoesNotCrash() {
        // Matches `fit(into:)`'s own degenerate fallback (scale 1, offset
        // .zero, pinned by `testDegenerateViewSizeDoesNotCrash`) — the
        // point passes through unchanged rather than the call crashing or
        // dividing by zero.
        let plane = AXDesktopPlane(desktopBounds: .zero, screenBounds: [])
        XCTAssertEqual(
            plane.axPoint(for: CGPoint(x: 5, y: 5), in: CGSize(width: 500, height: 500)),
            CGPoint(x: 5, y: 5))
    }

    // MARK: - focused(on:) — the zoom-viewport substitution

    func testFocusedReplacesDesktopBoundsButKeepsScreenBounds() {
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 2000, height: 1000)],
            primaryScreenHeight: 1000)
        let focus = CGRect(x: 100, y: 100, width: 200, height: 200)
        let zoomed = plane.focused(on: focus)

        XCTAssertEqual(zoomed.desktopBounds, focus)
        XCTAssertEqual(zoomed.screenBounds, plane.screenBounds, "still there for the screen outlines")
    }

    func testFocusedPlaneMagnifiesViewRects() {
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 1000)],
            primaryScreenHeight: 1000)
        let zoomed = plane.focused(on: CGRect(x: 400, y: 400, width: 100, height: 100))
        let viewSize = CGSize(width: 500, height: 500)

        // The same 10×10 AX rect reads far larger once the viewport is a
        // 100×100 region instead of the full 1000×1000 desktop.
        let atDesktopScale = plane.viewRect(
            for: CGRect(x: 405, y: 405, width: 10, height: 10), in: viewSize)
        let atZoomScale = zoomed.viewRect(
            for: CGRect(x: 405, y: 405, width: 10, height: 10), in: viewSize)
        XCTAssertEqual(atDesktopScale.width, 5, accuracy: 0.001)
        XCTAssertEqual(atZoomScale.width, 50, accuracy: 0.001)
    }

    func testFocusedThenAXPointRoundTrips() {
        let plane = AXDesktopPlane(
            cocoaScreenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 1000)],
            primaryScreenHeight: 1000)
        let zoomed = plane.focused(on: CGRect(x: 300, y: 300, width: 100, height: 100))
        let viewSize = CGSize(width: 400, height: 400)
        let axPoint = CGPoint(x: 340, y: 360)
        let viewPoint = zoomed.viewRect(for: CGRect(origin: axPoint, size: .zero), in: viewSize).origin
        let recovered = zoomed.axPoint(for: viewPoint, in: viewSize)
        XCTAssertEqual(recovered.x, axPoint.x, accuracy: 0.001)
        XCTAssertEqual(recovered.y, axPoint.y, accuracy: 0.001)
    }
}

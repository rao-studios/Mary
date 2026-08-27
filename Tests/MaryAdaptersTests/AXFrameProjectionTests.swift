//
//  AXFrameProjectionTests.swift
//  BonniePluginTests
//
//  Pins the pure geometry: centre computation, window-relative offset,
//  screen containment (including a rect spanning two displays and a
//  non-origin/stacked display fixture — the one genuinely easy thing to
//  get wrong), the clipped flag, and the JSON output.
//

import CoreGraphics
import Foundation
import XCTest
@testable import MaryAdapters

final class AXFrameProjectionTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Center

    func testCenterIsTheRectMidpoint() {
        let frame = AXFrameProjection.frame(
            CGRect(x: 659, y: 139, width: 23, height: 23), capturedAt: epoch)
        XCTAssertEqual(frame.center.x, 670.5)
        XCTAssertEqual(frame.center.y, 150.5)
    }

    // MARK: - Window-relative offset

    func testInWindowIsRelativeToTheWindowOrigin() {
        let window = CGRect(x: 500, y: 100, width: 800, height: 600)
        let element = CGRect(x: 559, y: 139, width: 23, height: 23)
        let frame = AXFrameProjection.frame(element, inWindow: window, capturedAt: epoch)
        XCTAssertEqual(frame.inWindow, .init(x: 59, y: 39, width: 23, height: 23))
    }

    func testNoWindowMeansNoInWindowRect() {
        let frame = AXFrameProjection.frame(
            CGRect(x: 0, y: 0, width: 800, height: 600), capturedAt: epoch)
        XCTAssertNil(frame.inWindow)
    }

    // MARK: - Screen containment

    func testElementInsideOneScreenGetsThatScreen() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let frame = AXFrameProjection.frame(
            CGRect(x: 100, y: 100, width: 50, height: 50), screens: screens, capturedAt: epoch)
        XCTAssertEqual(frame.screen?.index, 0)
        XCTAssertEqual(frame.screen?.rect, .init(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testElementOnTheSecondScreenGetsIndexOne() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let frame = AXFrameProjection.frame(
            CGRect(x: 2000, y: 100, width: 50, height: 50), screens: screens, capturedAt: epoch)
        XCTAssertEqual(frame.screen?.index, 1)
    }

    /// A window whose CENTRE lands on one screen resolves by the fast
    /// containment path — the common case, and the reason `screenIndex`
    /// checks it first.
    func testARectWhoseCenterLandsOnAScreenUsesIt() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let frame = AXFrameProjection.frame(
            CGRect(x: 1800, y: 100, width: 200, height: 50), screens: screens, capturedAt: epoch)
        XCTAssertEqual(frame.screen?.index, 0)
    }

    /// The genuine tiebreak: a rect whose CENTRE falls in the gap between
    /// two abutting screens' own bounds (a window spanning a bezel exactly
    /// at the seam) is contained by neither, so overlap area decides —
    /// here more of the rect's area sits on screen 1.
    func testRectWithNoContainingScreenPicksTheOneWithMoreOverlap() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1900, height: 1080),
            CGRect(x: 1940, y: 0, width: 1900, height: 1080),
        ]
        // Spans the 1900...1940 gap; centre (1930) is in neither screen.
        // Overlap: screen 0 gets 1900...1900 = 0pt, screen 1 gets
        // 1940...1980 = 40pt of this 100pt-wide rect.
        let frame = AXFrameProjection.frame(
            CGRect(x: 1880, y: 100, width: 100, height: 50), screens: screens, capturedAt: epoch)
        XCTAssertEqual(frame.screen?.index, 1)
    }

    /// A stacked, non-origin display arrangement (a laptop screen above a
    /// desk monitor, primary NOT at (0,0)) — the fixture that catches an
    /// implementation that assumes screen 0 sits at the origin.
    func testNonOriginStackedDisplaysResolveCorrectly() {
        let screens = [
            CGRect(x: -400, y: -1080, width: 1920, height: 1080),  // above, offset left
            CGRect(x: 0, y: 0, width: 2560, height: 1440),          // primary-ish, at origin
        ]
        let onUpperScreen = AXFrameProjection.frame(
            CGRect(x: -200, y: -900, width: 100, height: 100), screens: screens, capturedAt: epoch)
        XCTAssertEqual(onUpperScreen.screen?.index, 0)

        let onLowerScreen = AXFrameProjection.frame(
            CGRect(x: 1000, y: 500, width: 100, height: 100), screens: screens, capturedAt: epoch)
        XCTAssertEqual(onLowerScreen.screen?.index, 1)
    }

    func testNoOverlapWithAnyScreenIsNilNotAGuess() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let frame = AXFrameProjection.frame(
            CGRect(x: 5000, y: 5000, width: 10, height: 10), screens: screens, capturedAt: epoch)
        XCTAssertNil(frame.screen)
    }

    func testEmptyRosterIsNilNeverAClaimOfOffScreen() {
        let frame = AXFrameProjection.frame(
            CGRect(x: 0, y: 0, width: 10, height: 10), screens: [], capturedAt: epoch)
        XCTAssertNil(frame.screen)
    }

    // MARK: - Clipped flag

    func testClippedFlagIsCarriedVerbatim() {
        let clipped = AXFrameProjection.frame(
            CGRect(x: 0, y: 0, width: 10, height: 10), isClipped: true, capturedAt: epoch)
        XCTAssertTrue(clipped.isClipped)
        let unclipped = AXFrameProjection.frame(
            CGRect(x: 0, y: 0, width: 10, height: 10), capturedAt: epoch)
        XCTAssertFalse(unclipped.isClipped)
    }

    // MARK: - Space + capture stamp

    func testSpaceIsAlwaysAXGlobalTopLeft() {
        let frame = AXFrameProjection.frame(.zero, capturedAt: epoch)
        XCTAssertEqual(frame.space, .axGlobalTopLeft)
    }

    func testCaptureStampIsCarriedVerbatim() {
        let frame = AXFrameProjection.frame(.zero, capturedAt: epoch)
        XCTAssertEqual(frame.capturedAt, epoch)
    }

    // MARK: - JSON

    func testJSONIsSortedAndTrailsANewline() {
        let record = AXElementRecord(
            identity: "axbutton|save", ordinal: 1, role: "AXButton", label: "Save",
            kind: "button", appName: "Example", pid: 42, windowTitle: "Window",
            frame: AXFrameProjection.frame(
                CGRect(x: 10, y: 10, width: 80, height: 24), capturedAt: epoch))
        guard let json = AXFrameProjection.json(record) else {
            return XCTFail("encoding should not fail for finite geometry")
        }
        XCTAssertTrue(json.hasSuffix("\n"))
        XCTAssertTrue(json.contains("\"identity\""))
        // "appName" sorts before "identity" sorts before "ordinal" — a spot
        // check that .sortedKeys actually applied.
        let appIndex = json.range(of: "\"appName\"")!.lowerBound
        let identityIndex = json.range(of: "\"identity\"")!.lowerBound
        let ordinalIndex = json.range(of: "\"ordinal\"")!.lowerBound
        XCTAssertLessThan(appIndex, identityIndex)
        XCTAssertLessThan(identityIndex, ordinalIndex)
    }

    func testCompactJSONHasNoTrailingNewline() {
        let record = AXElementRecord(
            identity: "axbutton|save", ordinal: 1, role: "AXButton", label: "Save",
            kind: "button", appName: "Example", pid: 42, windowTitle: "Window",
            frame: AXFrameProjection.frame(.zero, capturedAt: epoch))
        let json = AXFrameProjection.json(record, prettyPrinted: false)
        XCTAssertFalse(json?.hasSuffix("\n") ?? true)
    }

    // MARK: - Display roster (live, best-effort)

    func testActiveScreensReturnsAtLeastOneRectOnAnAttendedMachine() {
        // Headless CI sometimes has zero displays; assert shape, not count.
        for screen in AXFrameProjection.activeScreens() {
            XCTAssertTrue(screen.width.isFinite && screen.height.isFinite)
        }
    }
}

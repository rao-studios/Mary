//
//  ScreenRegionCaptureTests.swift
//  MaryComputerUseTests
//
//  WHAT: look_at_screen first provenance is the tagged editor bbox.
//  OUT:  ScreenRegionCapture.chooseRegion
//

import CoreGraphics
import XCTest
@testable import MaryComputerUse

final class ScreenRegionCaptureTests: XCTestCase {

    func testDeclaredEditorFrameWinsOverCursorAndWindow() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let editor = CGRect(x: 80, y: 60, width: 700, height: 500)
        let (rect, provenance) = ScreenRegionCapture.chooseRegion(
            cursor: CGPoint(x: 10, y: 10),
            window: window,
            ancestors: [
                ScreenRegionCapture.Candidate(
                    role: "AXSplitGroup", frame: window)
            ],
            webArea: nil,
            contentChildren: [],
            hint: nil,
            declaredEditor: editor)
        XCTAssertEqual(provenance, .declaredEditor)
        XCTAssertEqual(rect, editor)
    }

    func testMissingDeclaredEditorFallsThroughToWindow() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 300)
        let (_, provenance) = ScreenRegionCapture.chooseRegion(
            cursor: .zero,
            window: window,
            ancestors: [],
            webArea: nil,
            contentChildren: [],
            hint: nil,
            declaredEditor: nil)
        XCTAssertEqual(provenance, .wholeWindow)
    }
}

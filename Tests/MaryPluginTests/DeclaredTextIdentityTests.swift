//
//  DeclaredTextIdentityTests.swift
//  MaryPluginTests
//
//  WHAT: Highlight keeps document identity; DeclaredTextSight hasHighlight.
//  OUT:  CodeSurfaceObserver / DeclaredTextSight
//

import CoreGraphics
import XCTest
import MaryAmbient
@testable import MaryPlugin

final class DeclaredTextIdentityTests: XCTestCase {

    func testHighlightKeepsObservedFileIdentity() {
        let observer = CodeSurfaceObserver(store: AmbientContextStore())
        let place = AmbientPlace.application("xcode")
        observer.adoptStandingFileForTests(
            place: place, file: "AbilityRuntime.swift", editorName: "Xcode")
        XCTAssertEqual(observer.observedPlace, place)
        XCTAssertEqual(observer.ambientLine, "In Xcode: AbilityRuntime.swift")
        XCTAssertEqual(
            observer.promptContribution(),
            "Looking at AbilityRuntime.swift in Xcode.")
    }

    func testSightPacketReportsANonemptyRangeAsHighlight() {
        let sight = DeclaredTextSight(
            place: .application("xcode"),
            identity: "axtextarea|abilityruntime.swift",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            documentTitle: "AbilityRuntime.swift",
            selectedRange: 10..<40)
        XCTAssertTrue(sight.hasHighlight)
        XCTAssertEqual(sight.documentTitle, "AbilityRuntime.swift")
    }

    func testEmptyRangeIsNotAHighlight() {
        let sight = DeclaredTextSight(
            place: .application("xcode"),
            identity: "axtextarea|abilityruntime.swift",
            frame: .zero,
            selectedRange: 12..<12)
        XCTAssertFalse(sight.hasHighlight)
    }
}

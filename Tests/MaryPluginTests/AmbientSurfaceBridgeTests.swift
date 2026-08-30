//
//  AmbientSurfaceBridgeTests.swift
//  MaryPluginTests
//
//  WHAT: Engine snapshot → tier-0 surface, identity parity with AffordanceResolver.
//  OUT:  AmbientSurfaceBridge
//

import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import MaryPlugin

final class AmbientSurfaceBridgeTests: XCTestCase {

    private let place = AmbientPlace(attention: .applications, application: "com.example.app")

    private func context(
        roles: [(role: String, label: String, category: AXNodeCategory)] =
            [("AXButton", "Save", .interactive)],
        frame: CGRect = CGRect(x: 10, y: 10, width: 80, height: 24),
        focusedLabel: String? = nil,
        webContentHost: Bool = false
    ) -> AXAmbientContext {
        let ids = AXIDVendor()
        var children = roles.enumerated().map { index, entry in
            AXSnapshotTestSupport.node(
                ids, role: entry.role, label: entry.label,
                frame: frame.offsetBy(dx: 0, dy: CGFloat(index) * 40),
                category: entry.category)
        }
        if let focusedLabel {
            children.append(AXSnapshotTestSupport.node(
                ids, role: "AXTextField", label: focusedLabel,
                frame: CGRect(x: 400, y: 10, width: 120, height: 22),
                category: .interactive, isFocused: true))
        }
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", category: .container, children: children)
        let windows = [AXSnapshotTestSupport.window(
            ids, title: "Document",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMain: true, root: root)]
        return AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app(windows),
            scope: .all, limit: AXElementRoster.publishedLimit,
            webContentHost: webContentHost,

            observersCovered: nil, observersTotal: nil)
    }

    // MARK: - Surface mapping

    func testSurfaceCarriesIdentityWindowAndElements() {
        let sample = context(focusedLabel: "Search")
        let surface = AmbientBridge.surface(from: sample, place: place)
        XCTAssertEqual(surface.place, place)
        XCTAssertEqual(surface.application.name, "Example")
        XCTAssertEqual(surface.application.bundleID, "com.example.app")
        XCTAssertEqual(surface.application.pid, 1)
        XCTAssertEqual(surface.activeWindow?.title, "Document")
        XCTAssertEqual(surface.windowCount, 1)
        XCTAssertEqual(surface.elements.count, sample.elements.count)
        XCTAssertEqual(surface.focused?.label, "Search")
        XCTAssertEqual(surface.focused?.kind, "field")
        XCTAssertEqual(surface.capturedAt, sample.capture.capturedAt)
        XCTAssertFalse(surface.pageNotYetRead)
    }

    func testSurfaceElementKeepsOrdinalTrailAndState() {
        let sample = context()
        let surface = AmbientBridge.surface(from: sample, place: place)
        let element = surface.elements.first
        XCTAssertEqual(element?.ordinal, sample.elements.first?.ordinal)
        XCTAssertEqual(element?.role, "AXButton")
        XCTAssertEqual(element?.kind, "button")
        XCTAssertEqual(element?.label, "Save")
        XCTAssertEqual(element?.isEnabled, true)
    }

    // MARK: - Geometry

    func testSurfaceElementCarriesAFrame() {
        let sample = context()
        let surface = AmbientBridge.surface(from: sample, place: place)
        let engineFrame = sample.elements.first!.frame
        let surfaceFrame = surface.elements.first?.frame
        XCTAssertEqual(surfaceFrame?.rect.x, engineFrame.origin.x)
        XCTAssertEqual(surfaceFrame?.rect.width, engineFrame.width)
        XCTAssertEqual(surfaceFrame?.center.x, engineFrame.midX)
        XCTAssertEqual(surfaceFrame?.capturedAt, sample.capture.capturedAt)
    }

    /// THE FIX: the focused element used to be built with no frame at all
    /// (`.zero` was passed only to kind derivation) — it is the single most
    /// act-relevant element on screen and carried no geometry.
    func testFocusedElementNowCarriesItsFrame() {
        let sample = context(focusedLabel: "Search")
        let surface = AmbientBridge.surface(from: sample, place: place)
        XCTAssertNotNil(surface.focused?.frame, "the focused element must carry a frame")
        XCTAssertEqual(surface.focused?.frame?.rect.x, 400)
        XCTAssertEqual(surface.focused?.frame?.rect.y, 10)
    }

    func testWindowFrameIsProjected() {
        let sample = context()
        let surface = AmbientBridge.surface(from: sample, place: place)
        XCTAssertNotNil(surface.activeWindow?.frame)
        XCTAssertEqual(surface.activeWindow?.frame?.rect.width, 800)
    }

    func testAffordancesCarryAFrame() {
        let sample = context()
        let affordances = AmbientBridge.affordances(from: sample)
        XCTAssertEqual(affordances.first?.frame?.rect.x, 10)
        XCTAssertEqual(affordances.first?.frame?.rect.y, 10)
    }

    func testInWindowIsRelativeToTheActiveWindow() {
        let sample = context()
        let surface = AmbientBridge.surface(from: sample, place: place)
        // The fixture's window sits at (0,0), so element-relative-to-window
        // equals the element's own global rect exactly.
        let engineFrame = sample.elements.first!.frame
        XCTAssertEqual(surface.elements.first?.frame?.inWindow?.x, engineFrame.origin.x)
        XCTAssertEqual(surface.elements.first?.frame?.inWindow?.y, engineFrame.origin.y)
    }

    // MARK: - The addressing record

    func testRecordCombinesIdentityAndGeometry() {
        let sample = context()
        guard let element = sample.elements.first else {
            return XCTFail("fixture produced no element")
        }
        let record = AmbientBridge.record(
            from: element, window: sample.activeWindow?.frame,
            capturedAt: sample.capture.capturedAt)
        XCTAssertEqual(record.identity, AmbientBridge.identity(of: element))
        XCTAssertEqual(record.label, "Save")
        XCTAssertEqual(record.kind, "button")
        XCTAssertEqual(record.frame.rect.x, element.frame.origin.x)
        XCTAssertEqual(record.appName, "Example")
        XCTAssertEqual(record.pid, 1)
    }

    func testRecordJSONRoundTripsThroughAXFrameProjection() throws {
        let sample = context()
        let element = try XCTUnwrap(sample.elements.first)
        let record = AmbientBridge.record(
            from: element, window: nil, capturedAt: sample.capture.capturedAt)
        let json = try XCTUnwrap(AXFrameProjection.json(record))
        XCTAssertTrue(json.contains("\"identity\""))
        XCTAssertTrue(json.contains(record.identity))
    }

    // MARK: - Kind parity table

    func testKindWordsMatchThePageLanePerRole() {
        let expectations: [(role: String, category: AXNodeCategory, word: String)] = [
            ("AXButton", .interactive, "button"),
            ("AXLink", .interactive, "link"),
            ("AXTextField", .interactive, "field"),
            ("AXPopUpButton", .interactive, "option"),
            ("AXCheckBox", .interactive, "button"),
            ("AXSlider", .interactive, "slider"),
            ("AXHeading", .text, "heading"),
            ("AXImage", .image, "image"),
            ("AXRow", .container, "row"),
        ]
        for expectation in expectations {
            let sample = context(
                roles: [(expectation.role, "Thing", expectation.category)],
                frame: CGRect(x: 10, y: 10, width: 80, height: 24))
            let affordances = AmbientBridge.affordances(from: sample)
            XCTAssertEqual(
                affordances.first?.roleWord, expectation.word,
                "\(expectation.role) should humanize to \(expectation.word)")
            let derived = PageElementKindDerivation.kind(
                role: expectation.role, subrole: nil, url: nil,
                label: "Thing", frame: .zero)
            XCTAssertEqual(
                affordances.first?.roleWord, derived.spokenWord,
                "\(expectation.role) must ride the page lane's own derivation")
        }
    }

    // MARK: - Identity parity

    func testIdentityMatchesAffordanceResolverByteForByte() {
        let sample = context(roles: [("AXButton", "Skip  Ads", .interactive)])
        guard let element = sample.elements.first else {
            return XCTFail("fixture produced no element")
        }
        let live = PageElement(
            ordinal: 1, role: "AXButton", subrole: nil, kind: .button,
            label: "Skip  Ads",
            frame: CGRect(x: 10, y: 10, width: 80, height: 24),
            axElement: AXUIElementCreateApplication(1))
        XCTAssertEqual(
            AmbientBridge.identity(of: element),
            AffordanceResolver.identity(of: live))
    }

    // MARK: - The collected-roles filter

    func testUncollectedRolesNeverBecomeAffordances() {
        let sample = context(roles: [
            ("AXButton", "Save", .interactive),
            ("AXStaticText", "A caption", .text),
            ("AXGroup", "Sidebar", .container),
        ])
        let affordances = AmbientBridge.affordances(from: sample)
        XCTAssertEqual(affordances.map(\.label), ["Save"])
    }

    func testNonInteractiveCollectedRolesNeedTheHumanFloor() {
        let tiny = context(
            roles: [("AXRow", "Result row", .container)],
            frame: CGRect(x: 10, y: 10, width: 400, height: 4))
        XCTAssertTrue(AmbientBridge.affordances(from: tiny).isEmpty)

        let humanSized = context(
            roles: [("AXRow", "Result row", .container)],
            frame: CGRect(x: 10, y: 10, width: 400, height: 20))
        XCTAssertEqual(
            AmbientBridge.affordances(from: humanSized).map(\.label), ["Result row"])
    }

    func testDisabledStateIsCarriedNotDropped() {
        let ids = AXIDVendor()
        let disabled = AXSnapshotTestSupport.node(
            ids, role: "AXButton", label: "Continue",
            frame: CGRect(x: 10, y: 10, width: 80, height: 24),
            category: .interactive, isEnabled: false)
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXGroup", category: .container, children: [disabled])
        let sample = AXAmbientContext(
            snapshot: AXSnapshotTestSupport.app([AXSnapshotTestSupport.window(
                ids, title: "W",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600), root: root)]),
            scope: .all, limit: AXElementRoster.publishedLimit,


            observersCovered: nil, observersTotal: nil)
        let affordances = AmbientBridge.affordances(from: sample)
        XCTAssertEqual(affordances.first?.isEnabled, false)
    }

    func testAffordanceOrdinalsAreContiguousAfterFiltering() {
        let sample = context(roles: [
            ("AXStaticText", "Caption", .text),
            ("AXButton", "One", .interactive),
            ("AXButton", "Two", .interactive),
        ])
        let affordances = AmbientBridge.affordances(from: sample)
        XCTAssertEqual(affordances.map(\.ordinal), [1, 2])
    }

    // MARK: - The honest page claim

    /// THE ONE THING THE DEFERRED WEB LANE STILL OWES. Chromium and Electron
    /// build no web-content accessibility hierarchy until an assistive client
    /// asks, so a plain walk of one finds the native shell and nothing
    /// inside — measured in Bonnie as one published element where 176
    /// existed. Mary cannot wake the tree without the wake lane, but she must
    /// not claim to have seen a page she did not see, and this flag is how
    /// the surface says so.
    func testAWebContentHostIsMarkedAsNotYetRead() {
        let hosted = context(webContentHost: true)
        XCTAssertTrue(AmbientBridge.surface(from: hosted, place: place).pageNotYetRead)
        XCTAssertFalse(AmbientBridge.surface(from: context(), place: place).pageNotYetRead)
    }
}

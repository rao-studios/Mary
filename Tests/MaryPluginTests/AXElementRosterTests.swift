//
//  AXElementRosterTests.swift
//  MaryPluginTests
//
//  WHAT: Unlabeled declared editors publish with a fallback name and a frame.
//  OUT:  AXElementRoster
//

import CoreGraphics
import XCTest
@testable import MaryPlugin

final class AXElementRosterTests: XCTestCase {

    func testUnlabeledDeclaredTextAreaIsPublishedWithFallbackNameAndFrame() {
        let ids = AXIDVendor()
        let editor = AXSnapshotTestSupport.node(
            ids, role: "AXTextArea", label: nil,
            frame: CGRect(x: 40, y: 80, width: 600, height: 400),
            category: .interactive, isFocused: true)
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXSplitGroup", label: "Editors",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            category: .container, children: [editor])
        let window = AXSnapshotTestSupport.window(
            ids, title: "AbilityRuntime.swift",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), root: root)
        let snapshot = AXSnapshotTestSupport.app([window], appName: "Xcode")

        let unlabeled = AXElementRoster.elements(in: snapshot, scope: .all)
        XCTAssertTrue(unlabeled.filter { $0.role == "AXTextArea" }.isEmpty)

        let tagged = AXElementRoster.elements(
            in: snapshot, scope: .all, declaredEditorRoles: ["AXTextArea"])
        let published = tagged.first { $0.role == "AXTextArea" }
        XCTAssertEqual(published?.label, "AbilityRuntime.swift")
        XCTAssertEqual(published?.frame, CGRect(x: 40, y: 80, width: 600, height: 400))
        XCTAssertEqual(published?.isFocused, true)
    }

    func testPreferredDeclaredEditorPicksFocusedSplitSibling() {
        let ids = AXIDVendor()
        let left = AXSnapshotTestSupport.node(
            ids, role: "AXTextArea", label: "left",
            frame: CGRect(x: 0, y: 0, width: 400, height: 400),
            category: .interactive, isFocused: false)
        let right = AXSnapshotTestSupport.node(
            ids, role: "AXTextArea", label: "right",
            frame: CGRect(x: 400, y: 0, width: 200, height: 200),
            category: .interactive, isFocused: true)
        let root = AXSnapshotTestSupport.node(
            ids, role: "AXSplitGroup", category: .container, children: [left, right])
        let window = AXSnapshotTestSupport.window(
            ids, title: "Split",
            frame: CGRect(x: 0, y: 0, width: 800, height: 400), root: root)
        let snapshot = AXSnapshotTestSupport.app([window])
        let elements = AXElementRoster.elements(
            in: snapshot, scope: .all, declaredEditorRoles: ["AXTextArea"])
        let preferred = AXElementRoster.preferredDeclaredEditor(
            in: elements, roles: ["AXTextArea"])
        XCTAssertEqual(preferred?.label, "right")
        XCTAssertEqual(preferred?.isFocused, true)
    }
}

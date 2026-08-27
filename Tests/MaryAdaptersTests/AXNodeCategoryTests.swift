//
//  AXNodeCategoryTests.swift
//  BonniePluginTests
//
//  Pins the role→category table Clyde's WireframeRenderer keys its stroke
//  styles on — total and pure, no AX IPC.
//

import XCTest
@testable import MaryAdapters

final class AXNodeCategoryTests: XCTestCase {

    func testInteractiveRolesFromThePageLanesCollectedRoles() {
        for role in [
            "AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
            "AXRadioButton", "AXPopUpButton", "AXMenuButton",
            "AXDisclosureTriangle", "AXComboBox", "AXSlider", "AXTab", "AXMenuItem",
        ] {
            XCTAssertEqual(
                AXNodeCategory.category(role: role), .interactive,
                "\(role) should classify as interactive")
        }
    }

    func testStructuralAndTextRoles() {
        XCTAssertEqual(AXNodeCategory.category(role: "AXWindow"), .window)
        XCTAssertEqual(AXNodeCategory.category(role: "AXScrollArea"), .scrollArea)
        XCTAssertEqual(AXNodeCategory.category(role: "AXImage"), .image)
        XCTAssertEqual(AXNodeCategory.category(role: "AXStaticText"), .text)
        XCTAssertEqual(AXNodeCategory.category(role: "AXHeading"), .text)
        XCTAssertEqual(AXNodeCategory.category(role: "AXGroup"), .container)
        XCTAssertEqual(AXNodeCategory.category(role: "AXRow"), .container)
    }

    /// A page root is its own category, not `.other` — which is what it was
    /// before the web sub-engine, meaning Clyde drew nothing for it and the
    /// builder's IPC diet skipped its label (see `AXEngine/Web/`).
    func testWebAreaIsItsOwnCategory() {
        XCTAssertEqual(AXNodeCategory.category(role: "AXWebArea"), .webArea)
        XCTAssertNotEqual(AXNodeCategory.category(role: "AXWebArea"), .other)
    }

    /// `.scripted` is synthesis-only: the scripting sub-engine's own role
    /// string must fall through the table like any other unknown, so the
    /// category can be reached ONLY by `ScriptedGraft` setting it directly.
    /// That is what makes a `.scripted` node impossible to confuse with
    /// something Accessibility actually said.
    func testTheSyntheticScriptedRoleIsNotInTheTable() {
        XCTAssertEqual(AXNodeCategory.category(role: "BonnieScripted"), .other)
    }

    func testUnknownRoleFallsBackToOther() {
        XCTAssertEqual(AXNodeCategory.category(role: "AXSomeFutureRole"), .other)
        XCTAssertEqual(AXNodeCategory.category(role: ""), .other)
    }

    func testEveryCollectedPageRoleIsAccountedFor() {
        // The exact set PageElementReader collects as pointable — every one
        // of these must be .interactive so Clyde's renderer draws the same
        // things the page lane treats as actionable.
        let collectedRoles: Set<String> = [
            "AXLink", "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
            "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXImage",
            "AXHeading", "AXDisclosureTriangle", "AXRow", "AXCell",
            "AXComboBox", "AXSlider", "AXTab", "AXMenuItem",
        ]
        let nonInteractiveButCollected: Set<String> = [
            "AXImage", "AXHeading", "AXRow", "AXCell",
        ]
        for role in collectedRoles {
            let category = AXNodeCategory.category(role: role)
            if nonInteractiveButCollected.contains(role) {
                XCTAssertNotEqual(category, .other, "\(role) should have a real category")
            } else {
                XCTAssertEqual(category, .interactive, "\(role) should classify as interactive")
            }
        }
    }
}

//
//  AccessibilityAnchorLocatorTests.swift
//  MaryComputerUseTests
//
//  WHAT: The exactly-one-match rule and the bounds around the search.
//  OUT:  AccessibilityAnchorLocator.locateCore
//  PIN:  A fake tree, so the rule is pinned without AX inter-process traffic.
//

import Foundation
import Testing
@testable import MaryComputerUse

@Suite struct AccessibilityAnchorLocatorTests {

    final class Node {
        let role: String?
        let identifier: String?
        let title: String?
        let value: String?
        var children: [Node]
        init(role: String? = nil, identifier: String? = nil, title: String? = nil,
             value: String? = nil, children: [Node] = []) {
            self.role = role; self.identifier = identifier
            self.title = title; self.value = value; self.children = children
        }
    }

    static func find(
        _ locator: PluginAccessibilityAnchorLocatorSchema, in root: Node
    ) -> Node? {
        AccessibilityAnchorLocator.locateCore(
            locator, root: root,
            children: { $0.children },
            role: { $0.role }, identifier: { $0.identifier },
            title: { $0.title }, value: { $0.value })
    }

    static func groupLocator(
        descendantTitle: String? = nil, descendantLabelText: String? = nil
    ) -> PluginAccessibilityAnchorLocatorSchema {
        PluginAccessibilityAnchorLocatorSchema(
            role: .group, identifier: "sidebar",
            descendantRole: descendantTitle == nil && descendantLabelText == nil ? nil : .button,
            descendantTitle: descendantTitle,
            descendantLabelText: descendantLabelText)
    }

    /// One container, one match.
    @Test func aUniqueContainerIsFound() {
        let target = Node(role: "AXGroup", identifier: "sidebar")
        let root = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", identifier: "toolbar"), target,
        ])
        #expect(Self.find(Self.groupLocator(), in: root) === target)
    }

    /// TWO MATCHES IS NOT "PICK THE FIRST". A locator that names two things
    /// names neither, and clicking a guess acts on something the user never
    /// said. Refusing is what lets the spoken failure be honest.
    @Test func anAmbiguousContainerRefuses() {
        let root = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", identifier: "sidebar"),
            Node(role: "AXGroup", identifier: "sidebar"),
        ])
        #expect(Self.find(Self.groupLocator(), in: root) == nil)
    }

    @Test func aMissingContainerRefuses() {
        let root = Node(role: "AXWindow", children: [Node(role: "AXGroup", identifier: "toolbar")])
        #expect(Self.find(Self.groupLocator(), in: root) == nil)
    }

    /// A descendant clause narrows within the container, and the same
    /// exactly-one rule applies one level down.
    @Test func aUniqueDescendantIsFound() {
        let button = Node(role: "AXButton", title: "Play")
        let root = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", identifier: "sidebar", children: [
                Node(role: "AXButton", title: "Pause"), button,
            ]),
        ])
        #expect(Self.find(Self.groupLocator(descendantTitle: "Play"), in: root) === button)
    }

    @Test func anAmbiguousDescendantRefuses() {
        let root = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", identifier: "sidebar", children: [
                Node(role: "AXButton", title: "Play"),
                Node(role: "AXButton", title: "Play"),
            ]),
        ])
        #expect(Self.find(Self.groupLocator(descendantTitle: "Play"), in: root) == nil)
    }

    /// A row's label may arrive as AXTitle or AXValue; both spell the same row.
    @Test(arguments: [true, false])
    func labelTextMatchesTitleOrValue(_ asTitle: Bool) {
        let row = Node(role: "AXButton",
                       title: asTitle ? "Episode 4" : nil,
                       value: asTitle ? nil : "Episode 4")
        let root = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", identifier: "sidebar", children: [row]),
        ])
        #expect(Self.find(Self.groupLocator(descendantLabelText: "Episode 4"), in: root) === row)
    }

    /// THE SEARCH IS BOUNDED. A tree deeper than the budget is another
    /// process's problem; an unbounded walk through a malformed one is a hang
    /// in Mary wearing that application's bug.
    @Test func theContainerSearchStopsAtItsBudget() {
        // A chain longer than the budget, with the target at the very end.
        var deepest = Node(role: "AXGroup", identifier: "sidebar")
        let target = deepest
        for _ in 0..<(AccessibilityAnchorLocator.containerBudget + 50) {
            deepest = Node(role: "AXGroup", identifier: "filler", children: [deepest])
        }
        #expect(Self.find(Self.groupLocator(), in: deepest) == nil)
        #expect(target.role == "AXGroup")
    }

    /// Roles arrive from the package as `button`; AX spells them `AXButton`.
    @Test func schemaRolesBecomeAccessibilityRoles() {
        #expect(AccessibilityAnchorLocator.axName(.button) == "AXButton")
        #expect(AccessibilityAnchorLocator.axName(.textField) == "AXTextField")
    }
}

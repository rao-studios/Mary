//
//  PageRosterFixture.swift
//  MaryPlugin
//
//  WHAT: One page read, written down — so a routing decision can be re-argued with no
//        browser, no grant and no screen.
//  IN:   mary-web-probe --save-roster  OUT: PageRouteCalibrationTests, --fixture
//  PIN:  A ROUTER IS A PURE FUNCTION OF A READ, AND THIS IS THE READ. Every wrong press
//        this lane has made was made against a real page nobody could put in a test: the
//        strip that won on page order, the echo that won on word cover. Recorded, each
//        becomes a fixture that fails until the rule that would have caught it exists.
//        ADDRESSES ARE MASKED ON THE WAY IN. The lane speaks site names and never URLs;
//        a fixture checked into the repository must not be the one place a query string
//        survives. What matters to the router about an address row is that it IS one.
//        GEOMETRY IS KEPT because a route says nothing about frames but a press does,
//        and a fixture that lost them could not be replayed through the actor later.
//

import CoreGraphics
import Foundation
import MaryComputerUse

public struct PageRosterFixture: Codable, Sendable {

    public struct Row: Codable, Sendable {
        public var ordinal: Int
        public var role: String
        public var label: String
        public var frame: [Double]
        public var isEnabled: Bool
        public var containerTrail: [String]
        public var affordance: String
        public var affordanceSource: String
        public var labelSource: String
        public var hints: [String]
        public var groupID: Int?
        public var confidence: Double
    }

    public struct Group: Codable, Sendable {
        public var id: Int
        public var kind: String
        public var title: String?
        public var memberOrdinals: [Int]
    }

    public var pageFrame: [Double]
    public var rows: [Row]
    public var groups: [Group]
    public var labeledFraction: Double

    /// What a row's label is replaced with when it is an address.
    ///
    /// PIN: THE SHAPE SURVIVES, THE IDENTITY DOES NOT. A results card prints its own
    /// destination above the link, and the router turns that row away for STARTING like
    /// an address — so a mask that dropped the scheme would record a page on which the
    /// rule under test cannot fire. What is stripped is the host and everything after it,
    /// which is the half that carries a site name and a query string.
    public static let maskedAddress = "https://(an address)"

    public init(roster: PageRoster) {
        pageFrame = PageRosterFixture.numbers(roster.pageFrame)
        labeledFraction = roster.map.labeledFraction
        rows = roster.elements.map { element in
            let annotation = roster.annotation(for: element)
            return Row(
                ordinal: element.ordinal,
                role: element.role,
                label: element.label.lowercased().hasPrefix("http")
                    ? PageRosterFixture.maskedAddress : element.label,
                frame: PageRosterFixture.numbers(element.frame),
                isEnabled: element.isEnabled,
                containerTrail: element.containerTrail,
                affordance: (annotation?.affordance ?? .none).rawValue,
                affordanceSource: (annotation?.affordanceSource ?? .unknown).rawValue,
                labelSource: (annotation?.labelSource ?? .textInside).rawValue,
                hints: annotation?.hints ?? [],
                groupID: annotation?.groupID,
                confidence: annotation?.confidence ?? 0)
        }
        groups = roster.map.groups.map {
            Group(id: $0.id, kind: $0.kind, title: $0.title, memberOrdinals: $0.memberOrdinals)
        }
    }

    /// The read again, as the router takes it.
    public func roster() -> PageRoster {
        var annotations: [Int: SeenElementAnnotation] = [:]
        let elements = rows.map { row -> AXScreenElement in
            annotations[row.ordinal] = SeenElementAnnotation(
                affordance: SeenAffordance(rawValue: row.affordance) ?? .none,
                affordanceSource: SeenAffordanceSource(rawValue: row.affordanceSource) ?? .unknown,
                labelSource: SeenLabelSource(rawValue: row.labelSource) ?? .textInside,
                hints: row.hints,
                groupID: row.groupID,
                confidence: row.confidence)
            return AXScreenElement(
                ordinal: row.ordinal,
                id: AXNodeID(raw: UInt(row.ordinal)),
                pid: 0,
                appName: "A Browser",
                windowID: AXNodeID(raw: 1),
                windowTitle: "A Page",
                role: row.role,
                category: AXNodeCategory.category(role: row.role),
                label: row.label,
                frame: PageRosterFixture.rect(row.frame),
                isEnabled: row.isEnabled,
                containerTrail: row.containerTrail,
                provenance: .seen)
        }
        return PageRoster(
            elements: elements,
            map: PageMapSummary(
                groups: groups.map {
                    SeenGroup(
                        id: $0.id, kind: $0.kind, title: $0.title,
                        memberOrdinals: $0.memberOrdinals)
                },
                annotations: annotations,
                labeledFraction: labeledFraction),
            pageFrame: PageRosterFixture.rect(pageFrame))
    }

    static func numbers(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
    }

    static func rect(_ numbers: [Double]) -> CGRect {
        guard numbers.count == 4 else { return .zero }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}

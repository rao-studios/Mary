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

public struct PageRosterFixture: Codable, Sendable, Equatable {

    public struct Row: Codable, Sendable, Equatable {
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
        /// WHAT THE SEAL DECIDED ABOUT THIS ROW, as `RowFacts.rawValue`.
        ///
        /// PIN: RECORDED, NOT RE-DERIVED. A replay exists to argue with the
        /// evidence the live read actually produced; re-deriving the facts on
        /// the way back in would replay a page the router never saw, and a rule
        /// change would then silently rewrite its own fixtures. Absent in a v1
        /// recording, where the facts are derived on demand exactly as they were.
        public var facts: Int?
        /// The kind the reading named, when it named one.
        public var kind: String?
        /// WHERE ON THE PAGE THE SEAL PUT IT — see `PageRegion`.
        ///
        /// PIN: RECORDED FOR THE SAME REASON `facts` IS, and missing for two
        /// rounds without anyone noticing. A region is decided at the seal from
        /// the page's own geometry; a recording that dropped it replayed a page
        /// with no places in it at all, so every rule that reads one — the gate
        /// that refuses "the third link in the sidebar" on a page with no
        /// sidebar, the list derivation that only groups the page's own column —
        /// was inert offline and could not be regression-tested. Absent in a
        /// recording made before it existed, which reads as a page whose seal
        /// named no places, exactly as it was.
        public var region: String?
        /// The site this row leads to, as a person would say it. A NAME, never
        /// an address — the same reason `maskedAddress` exists.
        public var site: String?
        /// An adjustable control's state and range, when the page published
        /// them — a progress bar's value and the video's length. Absent in a
        /// recording made before they were carried.
        public var value: Double?
        public var minimumValue: Double?
        public var maximumValue: Double?
    }

    public struct Group: Codable, Sendable, Equatable {
        public var id: Int
        public var kind: String
        public var title: String?
        public var memberOrdinals: [Int]
    }

    public var pageFrame: [Double]
    public var rows: [Row]
    public var groups: [Group]
    public var labeledFraction: Double
    /// 1 = the AX-shaped pair alone; 2 = rows carrying their own facts.
    public var version: Int?
    /// WHETHER A ROLE CLASSIFIER RAN. Without it the map still reads a page and
    /// every role is a shape's best guess, so the page simply looks bad — the
    /// one failure a reader must not mistake for a hard page.
    public var classified: Bool?
    /// What the read cost. ~220ms is the documented budget; seconds is a finding.
    public var readMilliseconds: Int?

    /// What a row's label is replaced with when it is an address.
    ///
    /// PIN: THE SHAPE SURVIVES, THE IDENTITY DOES NOT. A results card prints its own
    /// destination above the link, and the router turns that row away for STARTING like
    /// an address — so a mask that dropped the scheme would record a page on which the
    /// rule under test cannot fire. What is stripped is the host and everything after it,
    /// which is the half that carries a site name and a query string.
    public static let maskedAddress = "https://(an address)"

    /// Stated directly — for a test naming a page by hand, and for a runner
    /// re-encoding an older recording.
    public init(
        pageFrame: [Double] = [0, 0, 0, 0],
        rows: [Row] = [],
        groups: [Group] = [],
        labeledFraction: Double = 1,
        version: Int? = 2,
        classified: Bool? = true,
        readMilliseconds: Int? = nil
    ) {
        self.pageFrame = pageFrame
        self.rows = rows
        self.groups = groups
        self.labeledFraction = labeledFraction
        self.version = version
        self.classified = classified
        self.readMilliseconds = readMilliseconds
    }

    public init(roster: PageRoster) {
        pageFrame = PageRosterFixture.numbers(roster.pageFrame)
        labeledFraction = roster.map.labeledFraction
        version = 2
        classified = roster.classified
        readMilliseconds = roster.readDuration.map(PageRosterFixture.milliseconds)
        let rowsByOrdinal = Dictionary(
            roster.rows.map { ($0.ordinal, $0) }, uniquingKeysWith: { first, _ in first })
        let factsByOrdinal = Dictionary(
            roster.rows.map {
                ($0.ordinal, ($0.facts.rawValue, $0.kind?.rawValue, $0.region?.rawValue))
            },
            uniquingKeysWith: { first, _ in first })
        rows = roster.elements.map { element in
            let annotation = roster.annotation(for: element)
            let seen = factsByOrdinal[element.ordinal]
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
                confidence: annotation?.confidence ?? 0,
                facts: seen?.0,
                kind: seen?.1,
                region: seen?.2,
                site: rowsByOrdinal[element.ordinal]?.site,
                value: rowsByOrdinal[element.ordinal]?.value,
                minimumValue: rowsByOrdinal[element.ordinal]?.minimumValue,
                maximumValue: rowsByOrdinal[element.ordinal]?.maximumValue)
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
        let map = PageMapSummary(
            groups: groups.map {
                SeenGroup(
                    id: $0.id, kind: $0.kind, title: $0.title,
                    memberOrdinals: $0.memberOrdinals)
            },
            annotations: annotations,
            labeledFraction: labeledFraction)
        let frame = PageRosterFixture.rect(pageFrame)
        // A V1 RECORDING HAS NO ROWS TO GIVE, so the roster derives them on
        // demand — the same answer it gives a test that states a page by hand.
        guard (version ?? 1) >= 2 else {
            return PageRoster(
                elements: elements, map: map, pageFrame: frame,
                classified: classified ?? true,
                readDuration: readMilliseconds.map { .milliseconds($0) })
        }
        return PageRoster(
            rows: pageRows(), groups: pageGroups(),
            elements: elements, map: map, pageFrame: frame,
            classified: classified ?? true,
            readDuration: readMilliseconds.map { .milliseconds($0) })
    }

    /// The rows a v2 recording carries, facts and all.
    public func pageRows() -> [PageRow] {
        let groupByID = Dictionary(
            groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            let group = row.groupID.flatMap { groupByID[$0] }
            return PageRow(
                ordinal: row.ordinal,
                frame: PageRosterFixture.rect(row.frame),
                label: row.label,
                labelSource: SeenLabelSource(rawValue: row.labelSource) ?? .textInside,
                affordance: SeenAffordance(rawValue: row.affordance) ?? .none,
                affordanceSource: SeenAffordanceSource(rawValue: row.affordanceSource)
                    ?? .unknown,
                kind: row.kind.flatMap { PageElementKind(rawValue: $0) },
                role: row.role.isEmpty ? nil : row.role,
                group: group.map {
                    PageGroupRef(
                        id: $0.id,
                        kind: SeenGroupKind(rawValue: $0.kind) ?? .band,
                        title: $0.title)
                },
                hints: row.hints,
                confidence: row.confidence,
                isEnabled: row.isEnabled,
                facts: RowFacts(rawValue: row.facts ?? 0),
                region: row.region.flatMap { PageRegion(rawValue: $0) },
                provenance: .seen,
                site: row.site,
                value: row.value,
                minimumValue: row.minimumValue,
                maximumValue: row.maximumValue)
        }
    }

    public func pageGroups() -> [PageGroup] {
        groups.map {
            PageGroup(
                id: $0.id,
                kind: SeenGroupKind(rawValue: $0.kind) ?? .band,
                title: $0.title,
                memberOrdinals: $0.memberOrdinals)
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    static func numbers(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map(Double.init)
    }

    static func rect(_ numbers: [Double]) -> CGRect {
        guard numbers.count == 4 else { return .zero }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}

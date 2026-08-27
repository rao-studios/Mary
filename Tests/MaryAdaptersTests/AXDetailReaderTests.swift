//
//  AXDetailReaderTests.swift
//  BonniePluginTests
//
//  Pins THE DETAIL DIET by counting: a synthetic subtree, a source whose
//  every closure tallies its own invocations, and assertions on the exact
//  totals. The claims that matter — a container costs nothing, an unknown
//  role costs nothing, a secure field is never asked for its contents, the
//  attributed read never fires without a character count — are all
//  arithmetic here rather than prose in a header.
//
//  Also pins the budget's stop behavior, per-node degradation when an id
//  cannot be resolved, the centred text slice, and the role-plausibility
//  recheck that guards against a recycled `CFHash`. Pure: no live AX.
//

import CoreGraphics
import Foundation
import XCTest
@testable import MaryAdapters

final class AXDetailReaderTests: XCTestCase {

    // MARK: - A counting source

    /// One synthetic element: what the "live" side would answer, plus the
    /// tallies proving what was asked.
    private final class FakeElement {
        let role: String
        var stringValue: String?
        var numberValue: Double?
        var minValue: Double?
        var maxValue: Double?
        var placeholder: String?
        var help: String?
        var roleDescription: String?
        var url: String?
        var isSelected: Bool?
        var isExpanded: Bool?
        var characterCount: Int?
        var visibleRange: Range<Int>?
        var attributed: NSAttributedString?

        init(role: String) { self.role = role }
    }

    private final class Tally {
        var role = 0
        var stringValue = 0
        var numberValue = 0
        var minValue = 0
        var maxValue = 0
        var placeholder = 0
        var help = 0
        var roleDescription = 0
        var url = 0
        var isSelected = 0
        var isExpanded = 0
        var characterCount = 0
        var visibleRange = 0
        var attributedText = 0
        /// The ranges `attributedText` was actually asked for, in order.
        var requestedRanges: [Range<Int>] = []

        var total: Int {
            role + stringValue + numberValue + minValue + maxValue + placeholder + help
                + roleDescription + url + isSelected + isExpanded + characterCount
                + visibleRange + attributedText
        }
    }

    private func source(_ tally: Tally) -> AXDetailReader.AXDetailSource<FakeElement> {
        AXDetailReader.AXDetailSource<FakeElement>(
            role: { tally.role += 1; return $0.role },
            stringValue: { tally.stringValue += 1; return $0.stringValue },
            numberValue: { tally.numberValue += 1; return $0.numberValue },
            minValue: { tally.minValue += 1; return $0.minValue },
            maxValue: { tally.maxValue += 1; return $0.maxValue },
            placeholder: { tally.placeholder += 1; return $0.placeholder },
            help: { tally.help += 1; return $0.help },
            roleDescription: { tally.roleDescription += 1; return $0.roleDescription },
            url: { tally.url += 1; return $0.url },
            isSelected: { tally.isSelected += 1; return $0.isSelected },
            isExpanded: { tally.isExpanded += 1; return $0.isExpanded },
            characterCount: { tally.characterCount += 1; return $0.characterCount },
            visibleRange: { tally.visibleRange += 1; return $0.visibleRange },
            attributedText: { element, range in
                tally.attributedText += 1
                tally.requestedRanges.append(range)
                return element.attributed
            })
    }

    // MARK: - Fixtures

    private let ids = AXIDVendor()

    private func node(
        role: String, subrole: String? = nil, label: String? = nil,
        children: [AXNodeSnapshot] = []
    ) -> AXNodeSnapshot {
        AXSnapshotTestSupport.node(
            ids, role: role, subrole: subrole, label: label,
            frame: CGRect(x: 0, y: 0, width: 100, height: 20),
            category: AXNodeCategory.category(role: role, subrole: subrole),
            children: children)
    }

    /// A subtree with one node of every shape the diet branches on.
    private func mixedSubtree() -> AXNodeSnapshot {
        node(
            role: "AXGroup",
            children: [
                node(role: "AXStaticText", label: "text"),
                node(role: "AXButton", label: "button"),
                node(role: "AXSlider", label: "slider"),
                node(role: "AXCheckBox", label: "checkbox"),
                node(role: "AXTextField", label: "field"),
                node(role: "AXTextField", subrole: "AXSecureTextField", label: "password"),
                node(role: "AXImage", label: "image"),
                node(role: "AXLink", label: "link"),
                node(role: "AXPopUpButton", label: "popup"),
                node(role: "AXRow", label: "row"),
                node(role: "AXProgressIndicator", label: "progress"),
                node(role: "AXBonnieMysteryRole", label: "unknown"),
            ])
    }

    /// Resolve every id in the subtree to an element carrying that node's role.
    private func table(for subtree: AXNodeSnapshot) -> [AXNodeID: FakeElement] {
        var table: [AXNodeID: FakeElement] = [:]
        subtree.forEachNode { table[$0.id] = FakeElement(role: $0.role) }
        return table
    }

    private func read(
        _ subtree: AXNodeSnapshot,
        table: [AXNodeID: FakeElement],
        tally: Tally,
        budget: AXDetailReader.Budget = .zoom
    ) -> AXSubtreeDetail {
        AXDetailReader.readCore(
            subtree: subtree, lookup: { table[$0] }, source: source(tally), budget: budget)
    }

    // MARK: - The diet

    func testAContainerCostsNothing() {
        let subtree = node(role: "AXGroup")
        let tally = Tally()

        _ = read(subtree, table: table(for: subtree), tally: tally)

        XCTAssertEqual(tally.total, 0, "a container has no detail worth any IPC")
    }

    func testAnUnknownRoleCostsNothing() {
        let subtree = node(role: "AXBonnieMysteryRole")
        let tally = Tally()

        _ = read(subtree, table: table(for: subtree), tally: tally)

        XCTAssertEqual(tally.total, 0)
    }

    /// The claim the whole lane's cost model rests on.
    func testStructureIsNeverReadFromAX() {
        let subtree = mixedSubtree()
        let tally = Tally()

        let detail = read(subtree, table: table(for: subtree), tally: tally)

        // Every node was visited (13 = 1 group + 12 children) using only the
        // published tree; the source has no children closure to call at all.
        XCTAssertEqual(detail.nodesRead, 13)
    }

    func testAStaticTextIsAskedForItsValueAndItsRuns() {
        let subtree = node(role: "AXStaticText")
        var elements = table(for: subtree)
        elements[subtree.id]?.stringValue = "Hello"
        elements[subtree.id]?.characterCount = 5
        elements[subtree.id]?.attributed = NSAttributedString(string: "Hello")
        let tally = Tally()

        let detail = read(subtree, table: elements, tally: tally)

        XCTAssertEqual(tally.stringValue, 1)
        XCTAssertEqual(tally.characterCount, 1)
        XCTAssertEqual(tally.attributedText, 1)
        XCTAssertEqual(detail.nodes[subtree.id]?.textValue, "Hello")
        XCTAssertEqual(detail.nodes[subtree.id]?.textRuns.map(\.text), ["Hello"])
        XCTAssertEqual(tally.numberValue, 0, "text is not a value-bearing control")
    }

    /// `AXStaticText` frequently declines `kAXNumberOfCharacters`; the plain
    /// value must still arrive, and the expensive read must not fire.
    func testWithoutACharacterCountTheAttributedReadNeverFires() {
        let subtree = node(role: "AXStaticText")
        var elements = table(for: subtree)
        elements[subtree.id]?.stringValue = "Plain only"
        elements[subtree.id]?.characterCount = nil
        let tally = Tally()

        let detail = read(subtree, table: elements, tally: tally)

        XCTAssertEqual(tally.characterCount, 1)
        XCTAssertEqual(tally.attributedText, 0, "no range to ask about means no parameterized read")
        XCTAssertEqual(tally.visibleRange, 0)
        XCTAssertEqual(detail.nodes[subtree.id]?.textValue, "Plain only")
        XCTAssertTrue(detail.nodes[subtree.id]?.textRuns.isEmpty ?? false)
    }

    /// The rule that keeps a password out of a rendered reconstruction.
    func testASecureFieldIsNeverAskedForItsContents() {
        let bySubrole = node(role: "AXTextField", subrole: "AXSecureTextField")
        let byRole = node(role: "AXSecureTextField")

        for subtree in [bySubrole, byRole] {
            var elements = table(for: subtree)
            elements[subtree.id]?.stringValue = "hunter2"
            elements[subtree.id]?.characterCount = 7
            let tally = Tally()

            let detail = read(subtree, table: elements, tally: tally)

            XCTAssertEqual(tally.stringValue, 0, "\(subtree.role): value must never be read")
            XCTAssertEqual(tally.characterCount, 0)
            XCTAssertEqual(tally.attributedText, 0)
            XCTAssertEqual(tally.placeholder, 0)
            XCTAssertNil(detail.nodes[subtree.id]?.textValue)
        }
    }

    func testARangeControlIsAskedForValueAndBoundsOnly() {
        for role in ["AXSlider", "AXProgressIndicator", "AXScrollBar", "AXLevelIndicator"] {
            let subtree = node(role: role)
            var elements = table(for: subtree)
            elements[subtree.id]?.numberValue = 0.5
            elements[subtree.id]?.minValue = 0
            elements[subtree.id]?.maxValue = 1
            let tally = Tally()

            let detail = read(subtree, table: elements, tally: tally)

            XCTAssertEqual(tally.numberValue, 1, role)
            XCTAssertEqual(tally.minValue, 1, role)
            XCTAssertEqual(tally.maxValue, 1, role)
            XCTAssertEqual(tally.characterCount, 0, "\(role): not text-bearing")
            XCTAssertEqual(detail.nodes[subtree.id]?.numericValue, 0.5)
            XCTAssertEqual(detail.nodes[subtree.id]?.maximumValue, 1)
        }
    }

    /// Value-bearing roles that `AXNodeCategory` maps to `.other` — the
    /// reason the detail diet is role-first rather than category-first.
    func testValueBearingRolesOutsideEveryCategoryStillGetRead() {
        let progress = node(role: "AXProgressIndicator")
        XCTAssertEqual(progress.category, .other, "premise: this role has no category of its own")

        var elements = table(for: progress)
        elements[progress.id]?.numberValue = 0.25
        let tally = Tally()

        let detail = read(progress, table: elements, tally: tally)

        XCTAssertEqual(detail.nodes[progress.id]?.numericValue, 0.25)
    }

    func testAToggleIsAskedForItsStateNotItsBounds() {
        let subtree = node(role: "AXCheckBox")
        var elements = table(for: subtree)
        elements[subtree.id]?.numberValue = 1
        let tally = Tally()

        _ = read(subtree, table: elements, tally: tally)

        XCTAssertEqual(tally.numberValue, 1)
        XCTAssertEqual(tally.minValue, 0, "a checkbox has no range")
        XCTAssertEqual(tally.maxValue, 0)
    }

    func testAPopupIsAskedForItsCurrentChoice() {
        let subtree = node(role: "AXPopUpButton")
        var elements = table(for: subtree)
        elements[subtree.id]?.stringValue = "Monthly"
        let tally = Tally()

        let detail = read(subtree, table: elements, tally: tally)

        XCTAssertEqual(detail.nodes[subtree.id]?.textValue, "Monthly")
        XCTAssertEqual(tally.characterCount, 0, "a popup's value is a choice, not a document")
    }

    func testOnlyLinkImageAndWebAreaAreAskedForAURL() {
        for role in ["AXLink", "AXImage", "AXWebArea"] {
            let subtree = node(role: role)
            let tally = Tally()
            _ = read(subtree, table: table(for: subtree), tally: tally)
            XCTAssertEqual(tally.url, 1, role)
        }
        for role in ["AXButton", "AXStaticText", "AXGroup"] {
            let subtree = node(role: role)
            let tally = Tally()
            _ = read(subtree, table: table(for: subtree), tally: tally)
            XCTAssertEqual(tally.url, 0, role)
        }
    }

    func testOnlyInteractiveAndImageNodesPayForHelpAndRoleDescription() {
        for role in ["AXButton", "AXImage"] {
            let subtree = node(role: role)
            let tally = Tally()
            _ = read(subtree, table: table(for: subtree), tally: tally)
            XCTAssertEqual(tally.help, 1, role)
            XCTAssertEqual(tally.roleDescription, 1, role)
        }
        for role in ["AXStaticText", "AXGroup", "AXRow"] {
            let subtree = node(role: role)
            let tally = Tally()
            _ = read(subtree, table: table(for: subtree), tally: tally)
            XCTAssertEqual(tally.help, 0, role)
            XCTAssertEqual(tally.roleDescription, 0, role)
        }
    }

    func testOnlyFieldsPayForAPlaceholder() {
        let field = node(role: "AXTextField")
        let text = node(role: "AXStaticText")

        let fieldTally = Tally()
        _ = read(field, table: table(for: field), tally: fieldTally)
        XCTAssertEqual(fieldTally.placeholder, 1)

        let textTally = Tally()
        _ = read(text, table: table(for: text), tally: textTally)
        XCTAssertEqual(textTally.placeholder, 0)
    }

    func testRowsAndTabsPayForSelectionState() {
        let subtree = node(role: "AXRow")
        var elements = table(for: subtree)
        elements[subtree.id]?.isSelected = true
        elements[subtree.id]?.isExpanded = false
        let tally = Tally()

        let detail = read(subtree, table: elements, tally: tally)

        XCTAssertEqual(tally.isSelected, 1)
        XCTAssertEqual(tally.isExpanded, 1)
        XCTAssertEqual(detail.nodes[subtree.id]?.isSelected, true)
    }

    // MARK: - Budget

    func testTheNodeCapStopsTheReadAndMarksItTruncated() {
        let subtree = mixedSubtree()
        let budget = AXDetailReader.Budget(
            maxNodes: 5, textCap: 128, runCap: 8, totalTextCap: 1024)
        let tally = Tally()

        let detail = read(subtree, table: table(for: subtree), tally: tally, budget: budget)

        XCTAssertTrue(detail.isTruncated)
        XCTAssertEqual(detail.nodesRead, 5, "exactly the cap, not one node more")
    }

    func testAnUncappedReadIsNotMarkedTruncated() {
        let subtree = mixedSubtree()
        let detail = read(subtree, table: table(for: subtree), tally: Tally())

        XCTAssertFalse(detail.isTruncated)
        XCTAssertEqual(detail.nodesRead, subtree.subtreeCount)
    }

    func testTheRequestedRangeNeverExceedsTheTextCap() {
        let subtree = node(role: "AXTextArea")
        var elements = table(for: subtree)
        elements[subtree.id]?.characterCount = 10_000
        elements[subtree.id]?.attributed = NSAttributedString(string: "x")
        let budget = AXDetailReader.Budget(
            maxNodes: 10, textCap: 256, runCap: 8, totalTextCap: 4096)
        let tally = Tally()

        let detail = read(subtree, table: elements, tally: tally, budget: budget)

        XCTAssertEqual(tally.requestedRanges.first?.count, 256)
        XCTAssertEqual(detail.nodes[subtree.id]?.textTruncated, true)
    }

    /// The whole-payload ceiling, so a page of text areas cannot multiply
    /// `textCap` without bound.
    func testTheTotalTextCapBoundsThePayloadAcrossNodes() {
        let subtree = node(
            role: "AXGroup",
            children: (0..<4).map { _ in node(role: "AXTextArea") })
        var elements = table(for: subtree)
        for element in elements.values where element.role == "AXTextArea" {
            element.characterCount = 1000
            element.attributed = NSAttributedString(string: "x")
        }
        let budget = AXDetailReader.Budget(
            maxNodes: 10, textCap: 200, runCap: 8, totalTextCap: 500)
        let tally = Tally()

        _ = read(subtree, table: elements, tally: tally, budget: budget)

        let requested = tally.requestedRanges.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(requested, 500)
    }

    // MARK: - Degradation

    /// A node with no live element — synthesized, or destroyed between the
    /// walk and the read — costs a count and nothing else, and never stops
    /// its siblings from decorating.
    func testAnUnresolvableNodeIsSkippedWhileItsSiblingsStillDecorate() {
        let subtree = mixedSubtree()
        var elements = table(for: subtree)
        let vanished = subtree.children[0].id
        let sibling = subtree.children[1].id
        elements[sibling]?.help = "Commit the change"
        elements[vanished] = nil
        let tally = Tally()

        let detail = read(subtree, table: elements, tally: tally)

        XCTAssertEqual(detail.nodesSkipped, 1)
        XCTAssertEqual(detail.nodesRead, subtree.subtreeCount - 1)
        XCTAssertNil(detail.nodes[vanished])
        XCTAssertEqual(
            detail.nodes[sibling]?.help, "Commit the change",
            "the sibling button still decorated")
    }

    func testAnEmptyDecorationIsNotStored() {
        let subtree = node(role: "AXButton")
        let detail = read(subtree, table: table(for: subtree), tally: Tally())

        XCTAssertEqual(detail.nodesRead, 1)
        XCTAssertNil(
            detail.nodes[subtree.id],
            "a node whose every read declined adds nothing for the renderer to join")
    }

    func testCancellationStopsTheRead() {
        let subtree = mixedSubtree()
        let elements = table(for: subtree)
        let tally = Tally()

        let detail = AXDetailReader.readCore(
            subtree: subtree, lookup: { elements[$0] }, source: source(tally),
            budget: .zoom, isCancelled: { true })

        XCTAssertEqual(detail.nodesRead, 0)
        XCTAssertEqual(tally.total, 0)
    }

    // MARK: - The centred slice

    func testTheSliceIsCentredOnTheVisibleRangeNotItsHead() {
        let slice = AXDetailReader.readableRange(count: 1000, visible: 400..<600, cap: 50)

        XCTAssertEqual(slice.count, 50)
        XCTAssertEqual(slice, 475..<525, "centred on the middle of what the user is looking at")
    }

    func testAVisibleRangeInsideTheCapIsTakenWhole() {
        XCTAssertEqual(AXDetailReader.readableRange(count: 1000, visible: 400..<430, cap: 50), 400..<430)
    }

    func testWithoutAVisibleRangeTheHeadOfTheContentIsRead() {
        XCTAssertEqual(AXDetailReader.readableRange(count: 1000, visible: nil, cap: 50), 0..<50)
        XCTAssertEqual(AXDetailReader.readableRange(count: 20, visible: nil, cap: 50), 0..<20)
    }

    func testTheSliceIsClampedInsideTheContent() {
        let slice = AXDetailReader.readableRange(count: 100, visible: 80..<400, cap: 50)

        XCTAssertGreaterThanOrEqual(slice.lowerBound, 0)
        XCTAssertLessThanOrEqual(slice.upperBound, 100)
    }

    func testADegenerateRangeOrCapYieldsNothingToRead() {
        XCTAssertTrue(AXDetailReader.readableRange(count: 0, visible: nil, cap: 50).isEmpty)
        XCTAssertTrue(AXDetailReader.readableRange(count: 100, visible: nil, cap: 0).isEmpty)
    }

    // MARK: - Re-attachment plausibility

    func testARecycledIDIsCaughtByTheRoleRecheck() {
        let published = node(role: "AXButton")

        XCTAssertTrue(AXDetailReader.plausible(node: published, liveRole: "AXButton"))
        XCTAssertFalse(
            AXDetailReader.plausible(node: published, liveRole: "AXStaticText"),
            "the id now describes some other node")
        XCTAssertFalse(
            AXDetailReader.plausible(node: published, liveRole: nil),
            "an element that cannot state its role cannot be trusted")
    }
}

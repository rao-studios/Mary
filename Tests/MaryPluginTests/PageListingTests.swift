//
//  PageListingTests.swift
//  MaryPluginTests
//
//  WHAT: What the model is shown, and what the receipts believe.
//  PIN:  WHAT IS SPOKEN IS WHAT RESOLVES. A listing that numbers rows differently from
//        the resolver teaches the model to ask for the wrong thing and then reports it
//        as a miss. That equality is the point of the first test here.
//

import CoreGraphics
import Foundation
import MaryComputerUse
import MaryFoundation
import Testing
@testable import MaryPlugin

@Suite struct PageListingTests {

    private func roster(
        _ rows: [(role: String, label: String, affordance: SeenAffordance)],
        group: (kind: String, title: String?)? = nil
    ) -> PageRoster {
        let page = BrowsingFixtures.page(rows, group: group)
        return PageRoster(
            elements: page.elements, map: page.map,
            pageFrame: CGRect(x: 100, y: 200, width: 800, height: 600))
    }

    /// THE NUMBER BESIDE A ROW IS THE NUMBER THE RESOLVER COUNTS.
    @Test func theSpokenOrdinalIsTheResolvedOrdinal() {
        let roster = roster([
            (role: "AXLink", label: "Alpine touring boots reviewed", affordance: .press),
            (role: "AXTextField", label: "Search", affordance: .fill),
            (role: "AXLink", label: "The best touring boots this year", affordance: .press),
        ])
        let spoken = PageListing.spoken(roster, pageName: "Results")
        #expect(spoken.contains("link 1 — Alpine touring boots reviewed"))
        #expect(spoken.contains("link 2 — The best touring boots this year"))
        #expect(spoken.contains("field 1 — Search"))

        // And "the second link" resolves to the row the listing called link 2.
        switch ScreenElementResolver.resolve(
            phrase: "the second link", in: roster.actionable, preferShortestOnTie: false) {
        case .one(let element):
            #expect(element.label == "The best touring boots this year")
        default:
            Issue.record("the phrase the listing taught did not resolve")
        }
    }

    /// A DIALOG IS NAMED FIRST. Nothing behind it can be reached while it is up.
    @Test func anOverlayIsAnnouncedBeforeThePage() {
        var page = BrowsingFixtures.page([
            (role: "AXButton", label: "Accept all", affordance: .press),
            (role: "AXButton", label: "Reject all", affordance: .press),
            (role: "AXLink", label: "Something on the page behind", affordance: .press),
        ])
        page.map.groups = [SeenGroup(
            id: 0, kind: "overlay", title: "Your choices", memberOrdinals: [1, 2])]
        let roster = PageRoster(elements: page.elements, map: page.map)
        let spoken = PageListing.spoken(roster, pageName: "A Page")
        #expect(spoken.hasPrefix("Something is covering the page"))
        #expect(spoken.contains("Accept all"))
    }

    /// A GUESSED NAME SAYS SO. "button 4" is a position, not something anyone wrote.
    @Test func aSynthesizedNameIsMarkedUnnamed() {
        var page = BrowsingFixtures.page([
            (role: "AXButton", label: "button 4", affordance: .press),
        ])
        page.map.annotations[1] = SeenElementAnnotation(
            affordance: .press, labelSource: .synthesized)
        let roster = PageRoster(elements: page.elements, map: page.map)
        #expect(PageListing.spoken(roster, pageName: nil).contains("(unnamed)"))
    }

    /// A HINT RIDES ALONG WITHOUT BECOMING THE NAME.
    @Test func hintsAreShownSeparately() {
        var page = BrowsingFixtures.page([
            (role: "AXLink", label: "A video about boots · 12:34", affordance: .press),
        ])
        page.map.annotations[1] = SeenElementAnnotation(
            affordance: .press, labelSource: .textInside, hints: ["12:34", "sponsored"])
        let roster = PageRoster(elements: page.elements, map: page.map)
        let spoken = PageListing.spoken(roster, pageName: nil)
        #expect(spoken.contains("[12:34, sponsored]"))
    }

    /// THE TAIL FITS INSIDE ANOTHER SENTENCE.
    @Test func theTailIsBounded() {
        let rows = (0 ..< 30).map { index in
            (role: "AXLink", label: "A result with a fairly long title number \(index)",
             affordance: SeenAffordance.press)
        }
        let tail = PageListing.tail(roster(rows))
        #expect(tail.count <= PageListing.tailCharacterLimit)
        #expect(tail.hasPrefix("Now offering"))
    }

    /// AN EMPTY PAGE SAYS SO WITHOUT PRETENDING IT FAILED.
    @Test func anEmptyPageIsDescribedNotRefused() {
        let spoken = PageListing.spoken(
            PageRoster(elements: [], map: PageMapSummary()), pageName: "A Page")
        #expect(spoken.contains("nothing on it"))
    }
}

@Suite struct PageReceiptTests {

    private func look(
        title: String?, rows: [(role: String, label: String, affordance: SeenAffordance)]
    ) -> PageReceipts.Look {
        let page = BrowsingFixtures.page(rows)
        return PageReceipts.Look(
            shell: title.map { BrowsingFixtures.shell(title: $0, url: "https://example.com/\($0)") },
            roster: PageRoster(elements: page.elements, map: page.map))
    }

    private let click = PageInteractionPlanCommand(
        sourceIndex: 0, action: .click(.init(location: .target("A link"))))

    /// NAVIGATION OUTRANKS EVERYTHING, and it is the only evidence that survives a page
    /// replacing itself entirely.
    @Test func navigationIsTheStrongestEvidence() {
        let before = look(title: "Results", rows: [
            (role: "AXLink", label: "A link", affordance: .press),
        ])
        let after = look(title: "Somewhere else", rows: [
            (role: "AXLink", label: "Different entirely", affordance: .press),
        ])
        let effect = PageReceipts.judge(
            command: click, before: before, after: after,
            target: before.roster.elements.first, clickPoint: nil)
        guard case .verified(.navigation) = effect else {
            Issue.record("expected navigation, got \(effect)")
            return
        }
    }

    /// A TARGET THAT CHANGED IS PROOF; A PAGE THAT MERELY DIFFERS IS NOT.
    @Test func theTargetChangingIsProofAndARosterDiffIsNot() {
        let before = look(title: "A Page", rows: [
            (role: "AXButton", label: "Follow", affordance: .press),
            (role: "AXLink", label: "Something else", affordance: .press),
        ])
        let toggled = look(title: "A Page", rows: [
            (role: "AXButton", label: "Following", affordance: .press),
            (role: "AXLink", label: "Something else", affordance: .press),
        ])
        let target = before.roster.elements.first
        guard case .verified(.targetChanged) = PageReceipts.judge(
            command: click, before: before, after: toggled, target: target, clickPoint: nil)
        else {
            Issue.record("a changed target should be proof")
            return
        }

        let churned = look(title: "A Page", rows: [
            (role: "AXButton", label: "Follow", affordance: .press),
            (role: "AXLink", label: "An advert that rotated", affordance: .press),
            (role: "AXLink", label: "And another one", affordance: .press),
        ])
        guard case .weak(.rosterChanged) = PageReceipts.judge(
            command: click, before: before, after: churned, target: target, clickPoint: nil)
        else {
            Issue.record("a roster diff should be weak")
            return
        }
    }

    /// NOTHING AT ALL IS UNVERIFIED, which is a different sentence from success.
    @Test func anUnchangedPageProvesNothing() {
        let page = look(title: "A Page", rows: [
            (role: "AXButton", label: "Follow", affordance: .press),
        ])
        let effect = PageReceipts.judge(
            command: click, before: page, after: page,
            target: page.roster.elements.first, clickPoint: nil)
        #expect(effect == .unverified)
    }

    /// A TOOLTIP UNDER THE POINTER IS NOT AN EFFECT. Something appears there after
    /// almost every click, and counting it makes every click look successful.
    @Test func aBoxAppearingUnderThePointerIsIgnored() {
        let before = look(title: "A Page", rows: [
            (role: "AXButton", label: "Follow", affordance: .press),
            (role: "AXLink", label: "Something else", affordance: .press),
        ])
        var page = BrowsingFixtures.page([
            (role: "AXButton", label: "Follow", affordance: .press),
            (role: "AXLink", label: "Something else", affordance: .press),
            (role: "AXStaticText", label: "Follow this account", affordance: .none),
        ])
        // The tooltip sits where the click landed.
        page.elements[2].frame = CGRect(x: 150, y: 250, width: 160, height: 24)
        let after = PageReceipts.Look(
            shell: before.shell,
            roster: PageRoster(elements: page.elements, map: page.map))
        let effect = PageReceipts.judge(
            command: click, before: before, after: after,
            target: before.roster.elements.first,
            clickPoint: CGPoint(x: 160, y: 260))
        #expect(effect == .unverified)
    }

    /// THE SAME THING, IN A FRESH READING. Ids do not survive a re-read, so identity is
    /// the name and the role, and place breaks a tie.
    @Test func aRowIsRelocatedByNameThenByPlace() {
        let page = BrowsingFixtures.page([
            (role: "AXLink", label: "First", affordance: .press),
            (role: "AXLink", label: "Second", affordance: .press),
        ])
        let roster = PageRoster(elements: page.elements, map: page.map)
        var moved = page.elements[1]
        moved.ordinal = 99
        moved.id = AXNodeID(raw: 404)
        #expect(PageReceipts.relocate(moved, in: roster)?.label == "Second")

        var renamed = page.elements[0]
        renamed.label = "Something nobody wrote"
        #expect(PageReceipts.relocate(renamed, in: roster)?.label == "First")
    }
}

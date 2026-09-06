//
//  PageRegionTests.swift
//  MaryComputerUseTests
//
//  WHAT: The page's shape, from geometry alone.
//  PIN:  THE THREE PAGE SHAPES THE WEB ACTUALLY HAS, and each is a layout this
//        was measured against live before it was written down: a three-column
//        encyclopedia, a search page whose content sits left of centre, and a
//        single column. The rule has to answer all three without being told
//        which it is looking at.
//        A REGION IS NOT A LANDMARK. Nothing here reads markup, a role or a
//        site — a row is where it is, and that is the whole input.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryComputerUse

@Suite struct PageRegionTests {

    static let page = CGRect(x: 0, y: 0, width: 1200, height: 800)

    static func row(_ ordinal: Int, _ frame: CGRect, facts: RowFacts = []) -> PageRow {
        PageRow(ordinal: ordinal, frame: frame, label: "row \(ordinal)", facts: facts)
    }

    /// THE TOP BAND AND THE BOTTOM BAND ARE THE PAGE'S OWN EDGES.
    @Test func aRowAtTheTopIsInTheHeaderAndOneAtTheFootIsInTheFooter() {
        let rows = [
            Self.row(1, CGRect(x: 20, y: 10, width: 300, height: 30)),
            Self.row(2, CGRect(x: 400, y: 300, width: 400, height: 30)),
            Self.row(3, CGRect(x: 20, y: 770, width: 300, height: 20)),
        ]
        let placed = PageRegionDerivation.assign(rows: rows, pageFrame: Self.page)
        #expect(placed[0].region == .header)
        #expect(placed[2].region == .footer)
        // The middle row is the only content, so it IS the column.
        #expect(placed[1].region == .main)
    }

    /// A THREE-COLUMN PAGE SEPARATES INTO THREE COLUMNS.
    ///
    /// PIN: THE SHAPE OF AN ENCYCLOPEDIA ARTICLE, measured live: a narrow menu
    /// down the left, the article taking the middle, a short aside on the right.
    /// The column is found from where the page's row-area actually is, so the
    /// article wins it on bulk rather than on being called an article.
    @Test func aThreeColumnPageSeparates() {
        var rows: [PageRow] = []
        var ordinal = 0
        func add(_ frame: CGRect) { ordinal += 1; rows.append(Self.row(ordinal, frame)) }
        for index in 0..<6 { add(CGRect(x: 10, y: 200 + index * 40, width: 120, height: 20)) }
        for index in 0..<14 { add(CGRect(x: 320, y: 150 + index * 40, width: 520, height: 30)) }
        for index in 0..<4 { add(CGRect(x: 1000, y: 220 + index * 40, width: 160, height: 20)) }

        let placed = PageRegionDerivation.assign(rows: rows, pageFrame: Self.page)
        #expect(placed.prefix(6).allSatisfy { $0.region == .leading })
        #expect(placed.dropFirst(6).prefix(14).allSatisfy { $0.region == .main })
        #expect(placed.suffix(4).allSatisfy { $0.region == .trailing })
    }

    /// A SINGLE COLUMN IS ALL `main`, AND THAT IS AN ANSWER.
    ///
    /// PIN: THE FAILURE MODE THIS RULE HAD TO AVOID. A rule that always names a
    /// column would carve one out of a page's own margins and report the widest
    /// paragraph as a sidebar. `mainColumn` returns nil when no run narrower
    /// than the page carries it, and every middle row is `main`.
    @Test func aSingleColumnPageInventsNoSidebar() {
        let rows = (0..<12).map { index in
            Self.row(index + 1, CGRect(x: 150, y: 120 + index * 45, width: 900, height: 30))
        }
        let placed = PageRegionDerivation.assign(rows: rows, pageFrame: Self.page)
        #expect(placed.allSatisfy { $0.region == .main })
    }

    /// CONTENT LEFT OF CENTRE IS STILL THE CONTENT.
    ///
    /// PIN: THE SEARCH PAGE, AND THE MEASUREMENT THAT REWROTE THIS RULE. A first
    /// version took every slice that beat half the busiest one, so a dense strip
    /// of small controls set a peak its neighbours could not reach and the
    /// page's own results — immediately beside it — were reported as a sidebar.
    /// Asking for the narrowest run that carries most of the page instead lets
    /// the column grow to fit the content.
    @Test func aSearchPageWhoseContentSitsLeftOfCentreKeepsItAsMain() {
        var rows: [PageRow] = []
        var ordinal = 0
        func add(_ frame: CGRect) { ordinal += 1; rows.append(Self.row(ordinal, frame)) }
        // A dense strip of little chips, then the results beside and below them.
        for index in 0..<8 { add(CGRect(x: 180 + index * 30, y: 140, width: 26, height: 18)) }
        for index in 0..<10 { add(CGRect(x: 180, y: 200 + index * 55, width: 500, height: 45)) }

        let placed = PageRegionDerivation.assign(rows: rows, pageFrame: Self.page)
        #expect(placed.allSatisfy { $0.region == .main }, "\(placed.map { $0.region?.rawValue ?? "nil" })")
    }

    /// A DIALOG IS A PLACE TOO, AND IT IS NOT GEOMETRY.
    @Test func aRowInAnOverlayIsInTheOverlayWhereverItSits() {
        let rows = [
            Self.row(1, CGRect(x: 400, y: 300, width: 400, height: 40), facts: [.inOverlay]),
            Self.row(2, CGRect(x: 400, y: 400, width: 400, height: 40), facts: [.behindOverlay]),
        ]
        let placed = PageRegionDerivation.assign(rows: rows, pageFrame: Self.page)
        #expect(placed[0].region == .overlay)
        #expect(placed[1].region == .main)
    }

    // MARK: - The words

    /// A REGION THE PAGE HAS NONE OF IS NOT A REGION.
    @Test func onlyRegionsThePageHoldsCanBeNamed() {
        #expect(PageRegion.named(in: "the third link in the sidebar", among: [.main]) == nil)
        #expect(
            PageRegion.named(in: "the third link in the sidebar", among: [.main, .leading])
                == .leading)
    }

    /// LONGEST WORD FIRST, so a two-word place beats the one inside it.
    @Test func theLongerPlaceWins() {
        #expect(
            PageRegion.named(in: "the link in the right sidebar", among: [.leading, .trailing])
                == .trailing)
        #expect(PageRegion.named(in: "the button in the top bar", among: [.header]) == .header)
    }

    /// "BOTTOM" ALONE IS A POSITION, NOT A PLACE. See `admittingWords`.
    @Test func bottomAloneStaysAnOrdinal() {
        #expect(PageRegion.named(in: "the bottom link", among: [.footer, .main]) == nil)
        #expect(
            PageRegion.named(in: "the link at the bottom of the page", among: [.footer, .main])
                == .footer)
    }
}

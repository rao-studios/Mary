//
//  PagePlayerDerivationTests.swift
//  MaryComputerUseTests
//
//  WHAT: Where the picture is, and which rows are drawn over it.
//

import CoreGraphics
import Testing
@testable import MaryComputerUse

@Suite struct PagePlayerDerivationTests {

    static let page = CGRect(x: 0, y: 0, width: 1000, height: 800)

    static func row(
        _ ordinal: Int, _ frame: CGRect, label: String = "a row",
        affordance: SeenAffordance = .none, kind: PageElementKind? = nil
    ) -> PageRow {
        PageRow(ordinal: ordinal, frame: frame, label: label, affordance: affordance, kind: kind)
    }

    /// A SMALL PRESSABLE ROW OVER THE PICTURE IS AN OVERLAY — the fact a skip
    /// control needs to reach the router as the thing over the video.
    @Test func aControlOverThePictureIsAnOverlay() {
        let picture = CGRect(x: 100, y: 100, width: 800, height: 450)
        let rows = [
            Self.row(1, picture, label: "the picture", kind: .image),
            Self.row(2, CGRect(x: 760, y: 380, width: 110, height: 40), label: "Skip", affordance: .press),
            // The transport band along the bottom edge is not an overlay.
            Self.row(3, CGRect(x: 120, y: 520, width: 30, height: 24), label: "play", affordance: .press),
            // A link beside the picture is not over it.
            Self.row(4, CGRect(x: 100, y: 600, width: 300, height: 30), label: "Comments", affordance: .press),
        ]
        let marked = PagePlayerDerivation.markOverlays(rows: rows, pageFrame: Self.page)
        #expect(marked[1].facts.contains(.inOverlay))
        #expect(!marked[2].facts.contains(.inOverlay))
        #expect(!marked[3].facts.contains(.inOverlay))
        #expect(!marked[0].facts.contains(.inOverlay))
    }

    /// NO PICTURE, NOTHING MARKED: a page of prose has no overlay to invent.
    @Test func aPageWithNoPictureIsUntouched() {
        let rows = [
            Self.row(1, CGRect(x: 100, y: 100, width: 200, height: 30), label: "a heading"),
            Self.row(2, CGRect(x: 100, y: 140, width: 120, height: 30), label: "Skip", affordance: .press),
        ]
        let marked = PagePlayerDerivation.markOverlays(rows: rows, pageFrame: Self.page)
        #expect(marked.allSatisfy { !$0.facts.contains(.inOverlay) })
        #expect(PagePlayerDerivation.playerFrame(rows: rows, pageFrame: Self.page) == nil)
    }

    /// THE LARGEST VIDEO-SHAPED ROW IS THE PICTURE; a banner is too thin and a
    /// thumbnail too small.
    @Test func theLargestVideoShapedRowIsThePicture() {
        let picture = CGRect(x: 100, y: 100, width: 800, height: 450)
        let rows = [
            Self.row(1, CGRect(x: 0, y: 0, width: 1000, height: 60), kind: .image),   // a banner
            Self.row(2, CGRect(x: 100, y: 600, width: 160, height: 90), kind: .image),  // a thumbnail
            Self.row(3, picture, kind: .image),
        ]
        #expect(PagePlayerDerivation.playerFrame(rows: rows, pageFrame: Self.page) == picture)
    }
}

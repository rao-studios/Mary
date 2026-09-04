//
//  VisionPageReaderTests.swift
//  MaryComputerUseTests
//
//  WHAT: The seal — a page map crossing into Mary's own types, in screen points.
//  PIN:  THE PROJECTION IS THE POINT. A detection speaks in the captured image's pixels
//        and a click needs global screen points; handing a pixel rect on as if it were
//        a point rect was measured aiming a press 750 points away, on the wrong display.
//        Everything else here is vocabulary conversion, which is worth a test for the
//        same reason it is written as a switch: both sides are string-backed, and a
//        rawValue hop would answer wrongly the day either gains a case.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryComputerUse

@Suite struct VisionPageReaderTests {

    /// Rows arrive in screen points, carrying what the map said about them.
    @Test func theMapCrossesTheSealInScreenPoints() {
        let page = CGRect(x: 400, y: 300, width: 900, height: 700)
        let scene = SeenPageFixture.scene(
            pageOrigin: page.origin, pixelsPerPoint: 2,
            rows: [
                (label: "Alpine touring boots reviewed", role: "AXLink",
                 frame: CGRect(x: 40, y: 80, width: 600, height: 40), affordance: "press"),
                (label: "Search", role: "AXTextField",
                 frame: CGRect(x: 40, y: 20, width: 400, height: 40), affordance: "fill"),
            ])
        let (rows, summary) = VisionPageReader.rows(
            from: scene, pid: 42, appName: "A Browser", windowTitle: "A Page")

        #expect(rows.count == 2)
        // READING ORDER, so the field at the top comes first — which is also the order
        // the listing numbers and the resolver counts.
        #expect(rows.map(\.label) == ["Search", "Alpine touring boots reviewed"])
        // 2 pixels per point: a box at x 40 in pixels is 20 points from the page origin,
        // and 400 pixels wide is 200 points.
        let field = rows[0]
        #expect(field.frame.minX == page.minX + 20)
        #expect(field.frame.width == 200)
        #expect(field.provenance == .seen)
        #expect(field.pid == 42)
        #expect(summary.annotation(forOrdinal: field.ordinal)?.affordance == .fill)
        #expect(summary.annotation(forOrdinal: rows[1].ordinal)?.affordance == .press)
        #expect(summary.labeledFraction == 1)
    }

    /// A CONTROL WITH NO WORDS IN IT STILL CROSSES, named by its position and saying so.
    /// The alternative — dropping it — is what made a page of icons read as empty.
    @Test func aControlWithNoWordsIsNamedByPosition() {
        let scene = SeenPageFixture.scene(
            pageOrigin: .zero, pixelsPerPoint: 1,
            rows: [(label: "", role: "AXButton",
                    frame: CGRect(x: 10, y: 10, width: 40, height: 30), affordance: "press")],
            named: false)
        let (rows, summary) = VisionPageReader.rows(
            from: scene, pid: 1, appName: "A Browser", windowTitle: "A Page")
        #expect(rows.count == 1)
        #expect(rows[0].label == "button 1")
        #expect(summary.annotation(forOrdinal: 1)?.labelSource.isReal == false)
        #expect(summary.annotation(forOrdinal: 1)?.affordance == .press)
    }

    /// AND A LONE UNNAMED BOX IS NOT A CONTROL. A box nothing classified, with no words
    /// in it and nothing like it beside it, is a mark on the page.
    @Test func aLoneUnclassifiedBoxIsNotOffered() {
        let scene = SeenPageFixture.scene(
            pageOrigin: .zero, pixelsPerPoint: 1,
            rows: [(label: "", role: nil,
                    frame: CGRect(x: 10, y: 10, width: 30, height: 30), affordance: "none")],
            named: false)
        let (rows, _) = VisionPageReader.rows(
            from: scene, pid: 1, appName: "A Browser", windowTitle: "A Page")
        #expect(rows.isEmpty)
    }

    /// An overlay is reported, because nothing behind it can be reached.
    @Test func anOverlayIsCarriedAcross() {
        let scene = SeenPageFixture.scene(
            pageOrigin: .zero, pixelsPerPoint: 1,
            rows: [
                (label: "Accept all", role: "AXButton",
                 frame: CGRect(x: 320, y: 400, width: 120, height: 40), affordance: "press"),
                (label: "Reject all", role: "AXButton",
                 frame: CGRect(x: 460, y: 400, width: 120, height: 40), affordance: "press"),
            ],
            overlay: CGRect(x: 200, y: 200, width: 600, height: 400))
        let (_, summary) = VisionPageReader.rows(
            from: scene, pid: 1, appName: "A Browser", windowTitle: "A Page")
        #expect(summary.overlay != nil)
        // Everything inside it belongs to it, the buttons included.
        #expect((summary.overlay?.memberOrdinals.count ?? 0) >= 2)
    }
}

//
//  BrowserAffordanceSlateTests.swift
//  MaryPluginTests
//
//  Pins the browser half of the affordance carve-out.
//
//  TWO OBSERVERS WRITE ONE SCOPE, and the only thing keeping them from
//  disagreeing is that they read the same condition from opposite sides:
//  `AmbientSurfaceObserver` retracts when the front application IS a browser,
//  `BrowserSurfaceObserver` publishes only then. If those two tests ever stop
//  being the same test, the scope has two owners and the last poll to run
//  decides what a phrase resolves against.
//

import MaryAmbient
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class BrowserAffordanceSlateTests: XCTestCase {

    private func element(
        _ ordinal: Int, _ kind: PageElementKind, _ label: String, enabled: Bool = true
    ) -> PageElement {
        PageElement(
            ordinal: ordinal,
            role: "AXLink",
            kind: kind,
            label: label,
            frame: CGRect(x: 0, y: CGFloat(ordinal) * 40, width: 200, height: 30),
            isEnabled: enabled,
            axElement: AXUIElementCreateSystemWide())
    }

    // MARK: - Numbering

    /// THE ORDINAL IS THE ONE WITHIN ITS KIND, matching what
    /// `list_page_elements` reads aloud. If the index numbered differently
    /// from the list, "press video 3" would mean one thing when the model
    /// asked for the list and another when it resolved a phrase against the
    /// slate — and one of those presses the wrong thing.
    func testAffordancesAreNumberedWithinTheirKind() {
        let slate = BrowserSurfaceObserver.affordances(from: [
            element(1, .link, "Home"),
            element(2, .video, "Lesson One"),
            element(3, .link, "About"),
            element(4, .video, "Lesson Two"),
        ])
        XCTAssertEqual(slate.map(\.roleWord), ["link", "video", "link", "video"])
        XCTAssertEqual(slate.map(\.ordinal), [1, 1, 2, 2])
    }

    func testEachAffordanceKeepsItsLabelAndEnabledState() {
        let slate = BrowserSurfaceObserver.affordances(from: [
            element(1, .button, "Sign in"),
            element(2, .button, "Disabled thing", enabled: false),
        ])
        XCTAssertEqual(slate[0].label, "Sign in")
        XCTAssertTrue(slate[0].isEnabled)
        XCTAssertFalse(slate[1].isEnabled)
    }

    /// Identity carries the kind, the label AND the within-kind ordinal, so
    /// two links with the same words are two records rather than one
    /// overwriting the other.
    func testTwoControlsWithTheSameWordsGetDistinctIdentities() {
        let slate = BrowserSurfaceObserver.affordances(from: [
            element(1, .link, "hide"),
            element(2, .link, "hide"),
        ])
        XCTAssertNotEqual(slate[0].id, slate[1].id)
    }

    // MARK: - What the slate offers

    /// A field is pressable AND fillable; a heading is neither. The slate
    /// feeds a resolver that decides what a phrase may act on, so a wrong
    /// capability here is a press against a paragraph.
    func testCapabilitiesFollowTheRoleWord() {
        let records = AffordanceRule.records(
            for: BrowserSurfaceObserver.affordances(from: [
                element(1, .field, "Search"),
                element(2, .button, "Go"),
                element(3, .heading, "Results"),
            ]),
            scope: .affordances(in: AmbientPlaceResolver.browserPlace))

        let byName = Dictionary(
            uniqueKeysWithValues: records.map { ($0.name ?? "", $0.capabilities) })
        XCTAssertEqual(byName["Search"], [.pressable, .fillable])
        XCTAssertEqual(byName["Go"], [.pressable])
        XCTAssertEqual(byName["Results"], [])
    }

    /// AN UNLABELLED CONTROL CANNOT BE MEANT — there are no words to mean it
    /// with — so it never reaches the index. Pinned here because the page
    /// reader publishes plenty of them and a slate full of blanks would rank
    /// against every phrase equally badly.
    func testUnlabelledControlsNeverReachTheIndex() {
        let records = AffordanceRule.records(
            for: BrowserSurfaceObserver.affordances(from: [
                element(1, .button, ""),
                element(2, .button, "   "),
                element(3, .button, "Real"),
            ]),
            scope: .affordances(in: AmbientPlaceResolver.browserPlace))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].name, "Real")
    }

    // MARK: - The carve-out

    /// THE SCOPE THE TWO OBSERVERS SHARE. Both compute it from the browser
    /// PLACE rather than from the frontmost bundle, which is what makes it
    /// one scope for every browser — Safari and Chrome do not get a slate
    /// each, because the browser is one workspace.
    func testBothObserversAddressTheSameScope() {
        let place = AmbientPlaceResolver.browserPlace
        let scope = AmbientElementScope.affordances(in: place)
        XCTAssertEqual(scope, AmbientElementScope.affordances(in: place))
        XCTAssertTrue(scope.key.hasSuffix(AmbientElementScope.affordanceSuffix))
        // Chrome and Safari resolve to the SAME place, so the same slate.
        XCTAssertEqual(place, AmbientPlaceResolver.browserPlace)
    }

    /// The two observers are both registered, and exactly one of them claims
    /// the browser's affordances. A second publisher would not fail anything
    /// — it would just win races.
    func testExactlyOneObserverPublishesTheBrowserSlate() {
        let observers = MaryAdapterCatalog.observers()
        XCTAssertTrue(
            observers.contains { $0.id == "browser-page" },
            "the browser slate has no publisher; the carve-out is a promise kept on one side")
        XCTAssertTrue(observers.contains { $0.id == "ambient_surface" })

        // AND ITS ID IS NOT THE ADAPTER'S. Sharing one publishes two
        // manifests under a single identity, which `duplicate-adapter-manifest`
        // refuses by rejecting the ENTIRE package graph — every package
        // failing at once, blamed on an adapter nobody edited.
        let adapterIDs = Set(MaryAdapterCatalog.adapters().map(\.name))
        for observer in observers {
            XCTAssertFalse(
                adapterIDs.contains(observer.id),
                "observer \(observer.id) shares an adapter's id")
        }
    }
}

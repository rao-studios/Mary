//
//  BrowserTabRosterTests.swift
//  MaryPluginTests
//
//  Pins the two pure halves of the tab lane: how a strip becomes an ordered
//  roster with one current tab, and how a spoken target resolves against it.
//
//  Both are configurations a live browser produces only by chance — two tabs
//  whose pages share a title, a strip with unnamed tabs, a browser that
//  publishes no selection flag at all. Each is one fixture here and an
//  afternoon of tab-juggling in front of a real browser.
//

import ApplicationServices
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class BrowserTabRosterTests: XCTestCase {

    /// The two measured browsers, as declarations. Written out rather than
    /// loaded from the shipped packages so a package edit cannot quietly
    /// change what these tests mean.
    private var chromeLike: PluginBrowserSurfaceSchema {
        .init(
            tabStripRole: "AXTabGroup",
            tabRole: "AXRadioButton",
            tabNameAttribute: .description,
            selectionSignal: .selectedAttribute,
            closeAffordance: .childButton,
            closeControlLabel: "Close")
    }

    private var safariLike: PluginBrowserSurfaceSchema {
        .init(
            tabStripRole: "AXOpaqueProviderGroup",
            tabStripSubrole: "AXOpaqueProviderList",
            tabRole: "AXRadioButton",
            tabNameAttribute: .title,
            selectionSignal: .windowTitle,
            closeAffordance: .elementAction,
            closeControlLabel: "close tab")
    }

    /// A stand-in element. The assembly core never dereferences these — it
    /// only carries them through — which is exactly why it is testable.
    private var stub: AXUIElement { AXUIElementCreateSystemWide() }

    private func assemble(
        _ names: [String],
        selected: [Bool?]? = nil,
        windowTitle: String? = nil,
        surface: PluginBrowserSurfaceSchema
    ) -> [BrowserTabRoster.Tab] {
        BrowserTabRoster.assemble(
            names: names,
            selectedFlags: selected ?? Array(repeating: nil, count: names.count),
            windowTitle: windowTitle,
            surface: surface,
            element: { _ in stub })
    }

    // MARK: - Ordering

    func testTabsAreNumberedLeftToRightFromOne() {
        let tabs = assemble(["one", "two", "three"], surface: chromeLike)
        XCTAssertEqual(tabs.map(\.ordinal), [1, 2, 3])
        XCTAssertEqual(tabs.map(\.name), ["one", "two", "three"])
    }

    // MARK: - Which tab is current

    func testTheSelectedAttributeNamesTheCurrentTab() {
        let tabs = assemble(
            ["a", "b", "c"], selected: [false, true, false], surface: chromeLike)
        XCTAssertEqual(tabs.map(\.isCurrent), [false, true, false])
    }

    /// Safari publishes no flag, so the window title is the only signal. It
    /// usually carries decoration, so containment rather than equality.
    func testTheWindowTitleNamesTheCurrentTabWhenNoFlagIsPublished() {
        let tabs = assemble(
            ["Example Domain", "Wikipedia", "Hacker News"],
            windowTitle: "Hacker News",
            surface: safariLike)
        XCTAssertEqual(tabs.map(\.isCurrent), [false, false, true])
    }

    func testAWindowTitleWithDecorationStillMatches() {
        let tabs = assemble(
            ["Wikipedia", "Hacker News"],
            windowTitle: "Hacker News — Safari",
            surface: safariLike)
        XCTAssertEqual(tabs.last?.isCurrent, true)
    }

    /// TWO TABS SHOWING THE SAME PAGE is the documented weakness of the
    /// title signal, and it must surface as "cannot tell" rather than as a
    /// pick. Nil everywhere, not false everywhere.
    func testTwoTabsMatchingTheTitleLeaveCurrentUnknown() {
        let tabs = assemble(
            ["Hacker News", "Hacker News"],
            windowTitle: "Hacker News",
            surface: safariLike)
        XCTAssertEqual(tabs.map(\.isCurrent), [nil, nil])
    }

    /// FOUND LIVE, and a plain uniqueness test got it wrong. Safari showing
    /// "Accessibility - Wikipedia" while another tab is named plainly
    /// "Wikipedia" puts BOTH names inside the window title — so the first
    /// rule reported "cannot tell" for a browser with an obvious answer. A
    /// short name inside a longer one is not two rivals; it is a general
    /// name and a specific one, and the title is better explained by the
    /// specific.
    func testAShorterTabNameInsideALongerOneDoesNotCreateAmbiguity() {
        let tabs = assemble(
            ["Example Domain", "Wikipedia", "Hacker News", "Accessibility - Wikipedia"],
            windowTitle: "Accessibility - Wikipedia",
            surface: safariLike)
        XCTAssertEqual(tabs.map(\.isCurrent), [false, false, false, true])
    }

    /// But two DIFFERENT names of the same length both inside the title are
    /// genuinely indistinguishable, and the longest-match rule must not
    /// paper over that.
    func testTwoEquallySpecificMatchesAreStillUnknown() {
        let tabs = assemble(
            ["Alpha", "Bravo"],
            windowTitle: "Alpha and Bravo",
            surface: safariLike)
        XCTAssertEqual(tabs.map(\.isCurrent), [nil, nil])
    }

    /// A ROSTER REPORTING EVERY TAB `false` CLAIMS TO KNOW that none is
    /// current, which is never true of a browser with a window open. Absent
    /// is the honest value, and it is what sends the caller to a different
    /// sentence.
    func testNothingDecidingLeavesCurrentAbsentRatherThanFalse() {
        let tabs = assemble(["a", "b"], surface: chromeLike)
        XCTAssertEqual(tabs.map(\.isCurrent), [nil, nil])
    }

    /// THE DECLARED SIGNAL IS THE ONLY SIGNAL. Falling back from one to the
    /// other would paper over a package declaring the wrong one — and a
    /// browser silently mis-declared reports the wrong current tab forever.
    func testASurfaceDeclaringTheTitleSignalIgnoresASelectedFlag() {
        let tabs = assemble(
            ["a", "b"], selected: [false, true], windowTitle: nil, surface: safariLike)
        XCTAssertEqual(tabs.map(\.isCurrent), [nil, nil])
    }

    func testAnEmptyTabNameNeverMatchesTheWindowTitle() {
        let tabs = assemble(["", "Wikipedia"], windowTitle: "Wikipedia", surface: safariLike)
        XCTAssertEqual(tabs.map(\.isCurrent), [false, true])
    }

    // MARK: - Resolving what the user said

    private func resolve(
        _ target: BrowserTabRoster.Target, _ names: [String],
        selected: [Bool?]? = nil
    ) -> BrowserTabRoster.Resolution {
        BrowserTabRoster.resolve(
            target,
            in: assemble(names, selected: selected, surface: chromeLike))
    }

    func testAnOrdinalResolvesToThatTab() {
        guard case .one(let tab) = resolve(.ordinal(2), ["a", "b", "c"]) else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(tab.name, "b")
    }

    func testAnOrdinalPastTheEndSaysWhatWasThere() {
        guard case .refused(.noSuchTab(let offered)) = resolve(.ordinal(9), ["a", "b"]) else {
            return XCTFail("expected a miss naming the tabs")
        }
        XCTAssertEqual(offered, ["a", "b"])
    }

    func testAnExactNameWins() {
        guard case .one(let tab) = resolve(.named("Wikipedia"), ["Hacker News", "Wikipedia"])
        else { return XCTFail("expected a match") }
        XCTAssertEqual(tab.name, "Wikipedia")
    }

    /// A browser truncates a long tab name to fit the strip, so exact
    /// matching alone fails on precisely the tabs a person names by fragment.
    func testAUniqueFragmentMatches() {
        guard case .one(let tab) = resolve(.named("wiki"), ["Hacker News", "Wikipedia"])
        else { return XCTFail("expected a match") }
        XCTAssertEqual(tab.name, "Wikipedia")
    }

    /// EXACT BEATS CONTAINMENT. Otherwise naming a tab exactly is ambiguous
    /// whenever another tab's name happens to contain it.
    func testAnExactMatchBeatsALongerContainingOne() {
        guard case .one(let tab) = resolve(
            .named("News"), ["News", "Hacker News Daily"])
        else { return XCTFail("expected the exact match") }
        XCTAssertEqual(tab.name, "News")
    }

    /// A fragment matching three tabs is a question, not an answer — and the
    /// refusal names its rivals rather than shrugging.
    func testAnAmbiguousFragmentRefusesAndNamesTheRivals() {
        guard case .refused(.ambiguous(let rivals)) = resolve(
            .named("news"), ["Hacker News", "News Today", "Wikipedia"])
        else { return XCTFail("expected an ambiguity refusal") }
        XCTAssertEqual(rivals, ["Hacker News", "News Today"])
    }

    func testCurrentResolvesToTheFlaggedTab() {
        guard case .one(let tab) = resolve(
            .current, ["a", "b"], selected: [false, true])
        else { return XCTFail("expected the current tab") }
        XCTAssertEqual(tab.name, "b")
    }

    /// Asked for "this tab" when nothing says which one it is, naming the
    /// tabs is more use than guessing the first.
    func testCurrentWithNothingDecidingRefusesRatherThanGuessing() {
        guard case .refused(.ambiguous(let rivals)) = resolve(.current, ["a", "b"]) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(rivals, ["a", "b"])
    }

    /// An empty strip is Mary failing to READ, not the user naming something
    /// absent — and the two send a caller to different sentences.
    func testAnEmptyStripIsNoStripRatherThanNoSuchTab() {
        guard case .refused(.noStrip) = resolve(.ordinal(1), []) else {
            return XCTFail("expected noStrip")
        }
    }
}

//
//  WebSurfaceTests.swift
//  MaryPluginTests
//
//  WHAT: The pure decisions of the browsing lane — where the page is, which browser a
//        turn means, and what to call a site.
//  OUT:  WebSurfaceAX.pageFrame, BrowserTargetResolution, SiteName
//  PIN:  Every rule here was measured against a live browser and then written down as
//        arithmetic, so the next change to it fails here rather than on someone's screen.
//

import CoreGraphics
import Foundation
import Testing
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct WebSurfacePageFrameTests {

    /// Safari's window and toolbar, measured 2026-09-04.
    static let window = CGRect(x: -999, y: 117, width: 917, height: 842)
    static let toolbar = CGRect(x: -999, y: 117, width: 917, height: 52)

    /// THE WEB AREA'S FRAME IS THE WHOLE DOCUMENT, NOT THE VIEWPORT. Measured at 3101pt
    /// tall inside an 842pt window; capturing it unclipped asks for pixels that are not
    /// on screen and lands every click a screenful off.
    @Test func theWebAreaIsClippedToTheWindow() {
        let document = CGRect(x: -999, y: 207, width: 900, height: 3101)
        let (frame, source) = WebSurfaceAX.pageFrame(
            window: Self.window, toolbars: [Self.toolbar], webArea: document,
            source: .webArea)
        let page = try! #require(frame)
        #expect(page.minY == 207)
        #expect(page.maxY == Self.window.maxY, "the page cannot extend past its window")
        #expect(page.height == 752)
        #expect(source.contains("web area"))
    }

    /// A browser whose page tree is asleep publishes no web area at all, so the page is
    /// what is left under the lowest toolbar. Chrome stacks two — navigation and
    /// bookmarks — and the page starts under BOTH.
    @Test func theLowestToolbarBoundsThePage() {
        let window = CGRect(x: -1908, y: 35, width: 1150, height: 799)
        let navigation = CGRect(x: -1908, y: 75, width: 1150, height: 46)
        let bookmarks = CGRect(x: -1908, y: 121, width: 1150, height: 34)
        let (frame, source) = WebSurfaceAX.pageFrame(
            window: window, toolbars: [navigation, bookmarks], webArea: nil,
            source: .windowBelowToolbar)
        let page = try! #require(frame)
        #expect(page.minY == 155, "the bookmarks bar is the lowest one")
        #expect(page.height == 679)
        #expect(source.contains("toolbar"))
    }

    /// A NARROW STRIP IS NOT A TOOLBAR. A palette floating over the window would
    /// otherwise cut the page off at its own edge.
    @Test func aNarrowStripIsNotTakenForAToolbar() {
        let palette = CGRect(x: -900, y: 300, width: 120, height: 40)
        let (frame, _) = WebSurfaceAX.pageFrame(
            window: Self.window, toolbars: [Self.toolbar, palette], webArea: nil,
            source: .windowBelowToolbar)
        #expect(try! #require(frame).minY == 169, "the real toolbar still bounds it")
    }

    /// WITH NOTHING TO GO ON, THE WHOLE WINDOW IS THE HONEST ANSWER — and it says so,
    /// so a caller can tell a precise frame from a fallback.
    @Test func nothingKnownFallsBackToTheWindowAndAdmitsIt() {
        let (frame, source) = WebSurfaceAX.pageFrame(
            window: Self.window, toolbars: [], webArea: nil, source: .webArea)
        #expect(frame == Self.window)
        #expect(source.contains("whole window"))
    }

    @Test func noWindowIsNoFrame() {
        let (frame, _) = WebSurfaceAX.pageFrame(
            window: nil, toolbars: [], webArea: nil, source: .webArea)
        #expect(frame == nil)
    }
}

@Suite struct BrowserTargetResolutionTests {

    static let safari = "com.apple.Safari"
    static let chrome = "com.google.Chrome"
    static func isBrowser(_ id: String) -> Bool { id == safari || id == chrome }

    private func resolve(
        named: String? = nil, frontmost: String? = nil, fresh: String? = nil,
        recent: String? = nil, onScreen: [String] = [], running: [String] = []
    ) -> String? {
        BrowserTargetResolution.bundleID(
            named: named, frontmost: frontmost, freshEvidence: fresh,
            recentEvidence: recent, onScreen: onScreen, running: running,
            isBrowser: Self.isBrowser)
    }

    /// WORDS BEAT EVERYTHING. If the person said which browser, no ledger outranks it.
    @Test func aNamedBrowserWins() {
        #expect(resolve(
            named: Self.safari, frontmost: Self.chrome, fresh: Self.chrome,
            onScreen: [Self.chrome], running: [Self.safari, Self.chrome]) == Self.safari)
    }

    @Test func theFrontmostBrowserIsNext() {
        #expect(resolve(
            frontmost: Self.chrome, fresh: Self.safari,
            running: [Self.safari, Self.chrome]) == Self.chrome)
    }

    /// Something frontmost that is not a browser does not answer, and the ladder
    /// continues rather than stopping.
    @Test func aFrontmostNonBrowserIsSkipped() {
        #expect(resolve(
            frontmost: "com.apple.TextEdit", fresh: Self.safari,
            running: [Self.safari]) == Self.safari)
    }

    @Test func evidenceIsUsedWhenNothingIsInFront() {
        #expect(resolve(fresh: Self.safari, running: [Self.safari, Self.chrome]) == Self.safari)
        #expect(resolve(recent: Self.chrome, running: [Self.safari, Self.chrome]) == Self.chrome)
    }

    /// ONE VISIBLE BROWSER IS AN ANSWER.
    @Test func theOnlyBrowserOnScreenWins() {
        #expect(resolve(
            onScreen: [Self.chrome, "com.apple.TextEdit"],
            running: [Self.safari, Self.chrome]) == Self.chrome)
    }

    /// TWO VISIBLE BROWSERS AND NOTHING SAID IS A QUESTION, NOT A COIN FLIP. Acting on
    /// the wrong one navigates a window somebody was reading.
    @Test func twoVisibleBrowsersRefuseToGuess() {
        #expect(resolve(
            onScreen: [Self.safari, Self.chrome],
            running: [Self.safari, Self.chrome]) == nil)
    }

    @Test func theOnlyRunningBrowserWinsWithNothingOnScreen() {
        #expect(resolve(running: [Self.safari]) == Self.safari)
    }

    /// A BROWSER THAT IS NOT RUNNING IS NOT AN ANSWER, however it was reached.
    @Test func everyRungRequiresTheBrowserToBeRunning() {
        #expect(resolve(named: Self.safari, running: []) == nil)
        #expect(resolve(frontmost: Self.safari, running: [Self.chrome]) == Self.chrome)
    }

    @Test func nothingRunningIsNil() {
        #expect(resolve() == nil)
    }
}

@Suite struct SiteNameTests {

    @Test(arguments: [
        ("https://www.youtube.com/watch?v=aqz-KE-bpKQ", "youtube"),
        ("https://docs.google.com/document/d/1", "google docs"),
        ("https://news.ycombinator.com/", "ycombinator news"),
        ("https://developer.mozilla.org/en-US/", "mozilla developer"),
        ("youtube.com", "youtube"),
    ]) func aHostBecomesWhatAPersonWouldSay(_ url: String, _ spoken: String) {
        #expect(SiteName.spoken(url: url) == spoken)
    }

    /// A QUERY STRING NEVER SURVIVES. The video id in a YouTube address is the whole
    /// reason a URL must not be spoken back.
    @Test func nothingAfterTheHostSurvives() {
        let spoken = try! #require(SiteName.spoken(url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ"))
        #expect(!spoken.contains("aqz"))
        #expect(!spoken.contains("watch"))
    }

    @Test func somethingWithNoHostIsNotNamed() {
        #expect(SiteName.spoken(url: "") == nil)
        #expect(SiteName.spoken(url: "about:blank") == nil)
    }
}

/// THE BROWSER ARM OF THE AFFORDANCE LANE IS A DELEGATION, NOT A SECOND IMPLEMENTATION.
///
/// PIN: `act_on_screen` on a browser IS `click_on_page`. This suite reads the source
/// rather than driving it, because the thing worth protecting is structural: the day
/// somebody adds pressing code to the browser arm, there are two resolution ladders,
/// two receipt rules and two sets of refusals, and they part company the first time
/// either is fixed.
@Suite struct AffordanceBrowserArmTests {

    static func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The refusal is gone, and the arm that replaced it delegates.
    @Test func theBrowserArmDelegatesToTheEngine() throws {
        let body = try Self.source(
            "Sources/MaryPlugin/Adapters/Affordances/AffordanceRecipes.swift")
        #expect(!body.contains("I can't press things on one yet"))
        #expect(body.contains("case browser(BrowserTarget)"))
        #expect(body.contains("BrowserEngine.live.pressOnPage"))
        // Nothing in that file presses a page itself.
        #expect(!body.contains("clickThroughHID"))
    }

    /// The typer's browser refusal names a tool that exists.
    @Test func theTyperPointsAtARealTool() throws {
        let body = try Self.source(
            "Sources/MaryPlugin/Adapters/Typer/TyperPlugin+SkillBindings.swift")
        #expect(!body.contains("type_in_web_page"))
        #expect(body.contains("fill_in_page"))
    }

    /// The adapter no longer refuses what it now does.
    @Test func theAdapterDoesNotRefuseWhatItOffers() throws {
        let body = try Self.source("Sources/MaryPlugin/WebSurface/WebSurfaceAdapter.swift")
        #expect(!body.contains("I can't press things inside a page by name yet"))
        #expect(body.contains("read_page"))
        #expect(body.contains("search_web"))
    }
}

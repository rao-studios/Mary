//
//  BrowserTargetResolverTests.swift
//  MaryPluginTests
//
//  Pins the ladder that turns "the browser workspace" into one process.
//
//  Every rung here is an ORDERING claim, and an ordering bug does not throw:
//  it drives a different browser than the user meant, successfully. The two
//  worth staring at are the first and the last — a name outranking frontmost,
//  and two equal candidates refusing rather than picking.
//

import XCTest
@testable import MaryPlugin

final class BrowserTargetResolverTests: XCTestCase {

    private func candidate(
        _ bundleID: String,
        pid: pid_t,
        name: String,
        regular: Bool = true,
        frontmost: Bool = false,
        visible: Bool = true
    ) -> BrowserTargetResolver.Candidate {
        .init(
            bundleID: bundleID, processIdentifier: pid, localizedName: name,
            isRegularApplication: regular, isFrontmost: frontmost,
            hasVisibleWindow: visible)
    }

    private var safari: BrowserTargetResolver.Candidate {
        candidate("com.apple.Safari", pid: 100, name: "Safari")
    }
    private var chrome: BrowserTargetResolver.Candidate {
        candidate("com.google.Chrome", pid: 200, name: "Google Chrome")
    }

    /// Display names come from registrations in production; here they are a
    /// fixture so the ladder is tested without an installed package.
    private func resolve(
        named: String? = nil,
        pinned: BrowserTarget? = nil,
        evidenced: String? = nil,
        _ candidates: [BrowserTargetResolver.Candidate]
    ) -> BrowserTargetResolver.Resolution {
        BrowserTargetResolver.resolve(
            named: named, pinned: pinned, evidencedBundleID: evidenced,
            among: candidates,
            displayName: { bundleID in
                bundleID.hasPrefix("com.apple.Safari") ? "Safari"
                    : bundleID.hasPrefix("com.google.Chrome") ? "Google Chrome" : nil
            })
    }

    // MARK: - A name outranks everything

    /// "Reload it in Safari" while Chrome is frontmost means Safari. A ladder
    /// that let frontmost win would be confidently wrong in exactly the case
    /// where the user was most explicit.
    func testANamedBrowserBeatsTheFrontmostOne() {
        var front = chrome
        front.isFrontmost = true
        let result = resolve(named: "safari", [front, safari])
        XCTAssertEqual(result.decidedBy, .named)
        XCTAssertEqual(result.target?.bundleID, "com.apple.Safari")
    }

    func testANameMatchesTheRunningApplicationsOwnNameToo() {
        let result = resolve(named: "google chrome", [safari, chrome])
        XCTAssertEqual(result.target?.bundleID, "com.google.Chrome")
    }

    /// A NAME THAT MATCHES NOTHING STOPS THE LADDER. Falling through to
    /// frontmost would drive a different browser than the one named — worse
    /// than doing nothing, because nothing is visible and this is not.
    func testAnUnmatchedNameRefusesRatherThanFallingThrough() {
        var front = chrome
        front.isFrontmost = true
        let result = resolve(named: "firefox", [front])
        XCTAssertNil(result.target)
        XCTAssertEqual(result.decidedBy, .none)
    }

    // MARK: - The pin

    /// A turn drives ONE browser. Without the pin, a second act in the same
    /// turn re-runs the ladder against a world the first act just changed —
    /// and the browser it raised is now frontmost, so the answer can differ
    /// between two halves of one instruction.
    func testAPinnedTargetBeatsFrontmost() {
        var front = chrome
        front.isFrontmost = true
        let pin = BrowserTarget(
            bundleID: "com.apple.Safari", processIdentifier: 100, displayName: "Safari")
        let result = resolve(pinned: pin, [front, safari])
        XCTAssertEqual(result.decidedBy, .pinned)
        XCTAssertEqual(result.target?.processIdentifier, 100)
    }

    /// A pin outlives the process it named. Honouring a dead one would aim
    /// every keystroke of the turn at a pid that is gone, or worse, reused.
    func testAPinToADepartedProcessIsIgnored() {
        var front = chrome
        front.isFrontmost = true
        let stale = BrowserTarget(
            bundleID: "com.apple.Safari", processIdentifier: 999, displayName: "Safari")
        let result = resolve(pinned: stale, [front])
        XCTAssertEqual(result.decidedBy, .frontmost)
        XCTAssertEqual(result.target?.processIdentifier, 200)
    }

    // MARK: - The helper trap

    /// A browser's XPC helpers share its bundle prefix, are running, and have
    /// no windows — so an AX read against one returns nothing, which looks
    /// exactly like a browser showing an empty page. This is the filter.
    func testHelperProcessesAreNotBrowsers() {
        let helper = candidate(
            "com.apple.SafariPlatformSupport.Helper", pid: 101,
            name: "SafariPlatformSupport", regular: false, visible: false)
        let broker = candidate(
            "com.apple.Safari.SandboxBroker", pid: 102,
            name: "SandboxBroker", regular: false, visible: false)
        let result = resolve([helper, broker, safari])
        XCTAssertEqual(result.target?.processIdentifier, 100)
        // Not `.none`, and not a helper's pid: the helpers left the running
        // set entirely, so the real browser is the sole candidate rather than
        // one of three.
        XCTAssertEqual(result.decidedBy, .soleVisible)
    }

    /// And with ONLY helpers running, there is no browser — not a helper.
    func testHelpersAloneResolveToNothing() {
        let helper = candidate(
            "com.apple.SafariPlatformSupport.Helper", pid: 101,
            name: "SafariPlatformSupport", regular: false, visible: false)
        XCTAssertNil(resolve([helper]).target)
    }

    // MARK: - The lower rungs

    func testEvidenceDecidesWhenNothingIsFrontmost() {
        let result = resolve(evidenced: "com.google.Chrome", [safari, chrome])
        XCTAssertEqual(result.decidedBy, .evidenced)
        XCTAssertEqual(result.target?.bundleID, "com.google.Chrome")
    }

    /// Two running, one on screen: the one they can see is the one they mean.
    func testTheOnlyVisibleBrowserWinsOverAHiddenOne() {
        var hidden = chrome
        hidden.hasVisibleWindow = false
        let result = resolve([hidden, safari])
        XCTAssertEqual(result.decidedBy, .soleVisible)
        XCTAssertEqual(result.target?.bundleID, "com.apple.Safari")
    }

    /// TWO EQUAL CANDIDATES ARE NOT A COIN TOSS. Picking one is right half
    /// the time and never questioned; answering nothing lets the caller name
    /// both and ask.
    func testTwoEqualBrowsersRefuse() {
        let result = resolve([safari, chrome])
        XCTAssertNil(result.target)
        XCTAssertEqual(result.decidedBy, .none)
    }

    func testNoBrowsersAtAllResolvesToNothing() {
        let result = resolve([])
        XCTAssertNil(result.target)
        XCTAssertEqual(result.decidedBy, .none)
    }

    // MARK: - Naming

    /// The user hears the registration's display name, not a bundle id and
    /// not the process's own name where a package has said otherwise.
    func testTheTargetCarriesTheRegistrationsDisplayName() {
        let result = resolve([candidate("com.google.Chrome", pid: 200, name: "Chrome Canary")])
        XCTAssertEqual(result.target?.displayName, "Google Chrome")
    }

    /// A browser no registration names still gets called something — its own
    /// name is better than a bundle id, and far better than nothing.
    func testAnUnregisteredBrowserFallsBackToItsOwnName() {
        let result = resolve([candidate("org.mozilla.firefox", pid: 300, name: "Firefox")])
        XCTAssertEqual(result.target?.displayName, "Firefox")
    }
}

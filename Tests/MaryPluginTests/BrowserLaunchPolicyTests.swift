//
//  BrowserLaunchPolicyTests.swift
//  MaryPluginTests
//
//  Pins the rung below the bottom of the resolution ladder: when Mary may
//  open a browser, and — mostly — when she may not.
//
//  REUSE BEFORE LAUNCH is the property nearly every test here is about. A
//  second browser window appearing because a turn could not decide is a real
//  cost to the person watching, and it is the kind of bug that only shows up
//  on someone else's machine with someone else's browsers installed. So the
//  policy is pure and the rungs are pinned individually.
//

import XCTest
@testable import MaryPlugin

final class BrowserLaunchPolicyTests: XCTestCase {

    private let safari = BrowserLaunch.Declared(
        bundleIdentifiers: ["com.apple.Safari"], displayName: "Safari")
    private let chrome = BrowserLaunch.Declared(
        bundleIdentifiers: ["com.google.Chrome"], displayName: "Google Chrome")

    // MARK: - Reuse wins

    /// ⚠️ THE ONE THAT MATTERS MOST. The ladder answering nothing does not
    /// mean nothing is running — it commonly means TWO things are, and it
    /// could not choose. Opening a third browser is the worst possible answer
    /// to "which one?".
    func testTwoBrowsersRunningNeverLaunchesAThird() {
        let plan = BrowserLaunch.plan(
            named: nil,
            declared: [safari, chrome],
            runningBundleIDs: ["com.apple.Safari", "com.google.Chrome"])
        XCTAssertEqual(plan, .stand(.alreadyRunning))
    }

    func testABrowserAlreadyRunningIsNeverRelaunched() {
        let plan = BrowserLaunch.plan(
            named: nil, declared: [safari], runningBundleIDs: ["com.apple.Safari"])
        XCTAssertEqual(plan, .stand(.alreadyRunning))
    }

    /// Channel variants ride their release build's declaration everywhere else
    /// in this lane; a Canary counts as Chrome running here too, or Mary would
    /// launch a second Chrome beside the one already open.
    func testAChannelVariantCountsAsThatBrowserRunning() {
        let plan = BrowserLaunch.plan(
            named: nil, declared: [chrome], runningBundleIDs: ["com.google.Chrome.canary"])
        XCTAssertEqual(plan, .stand(.alreadyRunning))
    }

    // MARK: - Launching

    func testNothingRunningAndOneDeclaredOpensIt() {
        let plan = BrowserLaunch.plan(
            named: nil, declared: [safari], runningBundleIDs: [])
        XCTAssertEqual(plan, .launch(bundleID: "com.apple.Safari", displayName: "Safari"))
    }

    /// NOTHING RUNNING AND TWO DECLARED IS A COIN TOSS, and the same rule
    /// governs here as governs the ladder: picking is right half the time and
    /// is never questioned afterwards.
    func testNothingRunningAndTwoDeclaredRefusesToPick() {
        let plan = BrowserLaunch.plan(
            named: nil, declared: [safari, chrome], runningBundleIDs: [])
        XCTAssertEqual(plan, .stand(.ambiguous))
    }

    /// A NAME OUTRANKS EVERYTHING, exactly as in the ladder — and it is the
    /// one case where launching is unambiguous however many browsers are
    /// installed. "Open it in Safari" with Safari closed is a request to open
    /// Safari.
    func testANamedBrowserIsOpenedEvenWithAnotherRunning() {
        let plan = BrowserLaunch.plan(
            named: "Safari",
            declared: [safari, chrome],
            runningBundleIDs: ["com.google.Chrome"])
        XCTAssertEqual(plan, .launch(bundleID: "com.apple.Safari", displayName: "Safari"))
    }

    func testANamedBrowserAlreadyRunningIsNotRelaunched() {
        let plan = BrowserLaunch.plan(
            named: "Safari", declared: [safari], runningBundleIDs: ["com.apple.Safari"])
        XCTAssertEqual(plan, .stand(.alreadyRunning))
    }

    // MARK: - Only what a package declared

    /// Launching something Mary has no declaration for opens an application
    /// she then cannot drive — a failure that costs the user a window and
    /// teaches them nothing.
    func testABrowserNobodyDeclaredIsNeverOpened() {
        let plan = BrowserLaunch.plan(
            named: "Firefox", declared: [safari], runningBundleIDs: [])
        XCTAssertEqual(plan, .stand(.namedNotDeclared))
    }

    func testNoDeclarationsAtAllLaunchesNothing() {
        let plan = BrowserLaunch.plan(named: nil, declared: [], runningBundleIDs: [])
        XCTAssertEqual(plan, .stand(.nothingDeclared))
    }

    /// The first declared id, not whichever sorted first: a package lists the
    /// release build first and its channel variants after, and opening the
    /// Technology Preview because it sorted earlier would be a surprise.
    func testTheReleaseBuildIsPreferredOverAChannelVariant() {
        let both = BrowserLaunch.Declared(
            bundleIdentifiers: ["com.apple.Safari", "com.apple.SafariTechnologyPreview"],
            displayName: "Safari")
        let plan = BrowserLaunch.plan(named: nil, declared: [both], runningBundleIDs: [])
        XCTAssertEqual(plan, .launch(bundleID: "com.apple.Safari", displayName: "Safari"))
    }
}

//
//  ApplicationMenuDriverTests.swift
//  MaryPluginTests
//
//  Pins the menu driver's title matching and its refusal sentences.
//
//  The walk itself needs a live menu bar and is exercised by
//  `mary-corpus-probe menus`. What is testable here is the part that decides
//  whether two spellings of a command are the same command — which is where
//  a declared path silently fails to match a menu that is plainly there.
//

import XCTest
@testable import MaryPlugin

final class ApplicationMenuDriverTests: XCTestCase {

    // MARK: - Matching a title

    /// AN ELLIPSIS IS THE APPLICATION'S, NOT THE AUTHOR'S. A command that
    /// opens a dialog is titled "Project Settings…" in the menu, and a
    /// package author writing that path down naturally types "Project
    /// Settings". Neither spelling is wrong, so neither may be required.
    func testAnEllipsisIsIgnoredInEitherDirection() {
        XCTAssertEqual(
            ApplicationMenuDriver.normalized("Project Settings…"),
            ApplicationMenuDriver.normalized("Project Settings"))
        // The three-dot spelling too — some applications use it, and a
        // package author copying from a screenshot cannot tell which.
        XCTAssertEqual(
            ApplicationMenuDriver.normalized("Statistics..."),
            ApplicationMenuDriver.normalized("Statistics"))
    }

    func testMatchingIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(
            ApplicationMenuDriver.normalized("  Move To  "),
            ApplicationMenuDriver.normalized("move to"))
    }

    /// But it is not fuzzy beyond that: two genuinely different commands must
    /// not collapse, or a path lands on the wrong one and presses it.
    func testDifferentCommandsDoNotCollapse() {
        XCTAssertNotEqual(
            ApplicationMenuDriver.normalized("Move To"),
            ApplicationMenuDriver.normalized("Copy To"))
        XCTAssertNotEqual(
            ApplicationMenuDriver.normalized("New Folder"),
            ApplicationMenuDriver.normalized("New Folder from Selection"))
    }

    // MARK: - What a failure says

    /// THE LEVEL THAT WAS MISSING IS THE WHOLE VALUE of the failure. A
    /// missing leaf is usually the user's project not having that folder; a
    /// missing middle is usually a version change; a missing top is usually
    /// the wrong application. One sentence cannot serve all three.
    func testAMissingLevelNamesItselfAndWhereItWasLookedFor() {
        let deep = ApplicationMenuDriver.Failure.missingItem(
            "Status", inPath: ["Documents"])
        let spoken = deep.spoken(app: "Scrivener")
        XCTAssertTrue(spoken.contains("Status"))
        XCTAssertTrue(spoken.contains("Documents"))

        let top = ApplicationMenuDriver.Failure.missingItem("Documents", inPath: [])
        XCTAssertTrue(top.spoken(app: "Scrivener").contains("no Documents menu"))
    }

    /// DISABLED IS NOT MISSING, and telling them apart is the difference
    /// between "your version doesn't have that" and "select something first".
    /// Measured live: Scrivener's "Move to Trash" and "Split at Selection"
    /// are both present and both greyed out with nothing selected.
    func testADisabledCommandSaysSoRatherThanReadingAsAbsent() {
        let spoken = ApplicationMenuDriver.Failure
            .itemDisabled("Move to Trash").spoken(app: "Scrivener")
        XCTAssertTrue(spoken.contains("greyed out"))
        XCTAssertFalse(spoken.lowercased().contains("couldn't find"))
    }

    func testAnUnpressableCommandIsDistinctFromAMissingOne() {
        let refused = ApplicationMenuDriver.Failure.pressRefused("Merge")
        XCTAssertTrue(refused.spoken(app: "Scrivener").contains("didn't respond"))
    }
}

//
//  PageInteractionPlanTests.swift
//  MaryPluginTests
//
//  Pins the plan grammar and its admission — the half of `interact_with_page`
//  that decides whether anything is pressed at all.
//
//  ADMISSION IS WHERE THIS LANE IS MOST DANGEROUS, which is why it is pure
//  and tested here rather than discovered live. A plan that fails at step
//  four has already done steps one to three, and half a login is worse than
//  none: the user cannot see which half happened, and the page is in a state
//  neither they nor Mary described.
//

import XCTest
@testable import MaryPlugin

final class PageInteractionPlanTests: XCTestCase {

    private func parse(_ raw: String) -> [PageInteractionStep]? {
        guard case .success(let steps) = PageInteractionPlan.parse(raw) else { return nil }
        return steps
    }

    // MARK: - Reading what the model wrote

    func testALineIsAVerbAColonAndATarget() {
        let steps = parse("""
        press: Sign in
        reveal: Terms
        """)
        XCTAssertEqual(steps?.map(\.verb), [.press, .reveal])
        XCTAssertEqual(steps?.map(\.target), ["Sign in", "Terms"])
    }

    /// `target = text`, split on the FIRST `=` — a password containing one is
    /// a password, not a syntax error.
    func testAFillSplitsOnTheFirstEqualsOnly() {
        let steps = parse("fill: Password = a=b=c")
        XCTAssertEqual(steps?.first?.target, "Password")
        XCTAssertEqual(steps?.first?.text, "a=b=c")
    }

    func testBlankLinesAreSkippedRatherThanFailing() {
        let steps = parse("""
        press: One

        press: Two
        """)
        XCTAssertEqual(steps?.count, 2)
    }

    /// A LINE THAT IS NOT A STEP GETS ITS OWN MESSAGE. "I couldn't read that
    /// line" and "that step contradicts itself" send the author to different
    /// places, so they are different cases.
    func testAnUnreadableLineSaysSoAndListsTheVerbs() {
        guard case .failure(let issue) = PageInteractionPlan.parse("just do the thing") else {
            return XCTFail("expected a parse failure")
        }
        guard case .unreadableLine = issue else {
            return XCTFail("expected unreadableLine, got \(issue)")
        }
        XCTAssertTrue(issue.spoken.contains("press"))
        XCTAssertTrue(issue.spoken.contains("fill"))
    }

    func testAnUnknownVerbIsUnreadableRatherThanIgnored() {
        guard case .failure = PageInteractionPlan.parse("frobnicate: the widget") else {
            return XCTFail("an unknown verb must not be silently dropped")
        }
    }

    // MARK: - Admission

    func testAWellFormedPlanIsAdmitted() {
        let steps = parse("""
        fill: Email = someone@example.com
        fill: Password = hunter2
        press: Sign in
        """)!
        XCTAssertTrue(PageInteractionPlan.validate(steps).isEmpty)
    }

    func testAnEmptyPlanIsRefused() {
        XCTAssertEqual(PageInteractionPlan.validate([]), [.empty])
    }

    /// A BOUND, NOT A SUGGESTION. A sequence needing more steps than this is
    /// a task the user should be watching.
    func testTooManyStepsIsRefusedWholesale() {
        let many = Array(
            repeating: PageInteractionStep(verb: .press, target: "x"),
            count: PageInteractionPlan.maximumSteps + 1)
        XCTAssertEqual(
            PageInteractionPlan.validate(many),
            [.tooManySteps(PageInteractionPlan.maximumSteps + 1)])
    }

    func testAPressWithNoTargetIsRefused() {
        let issues = PageInteractionPlan.validate([.init(verb: .press, target: "  ")])
        XCTAssertEqual(issues, [.missingTarget(0, .press)])
    }

    func testAFillWithNoTextIsRefused() {
        let issues = PageInteractionPlan.validate([.init(verb: .fill, target: "Email")])
        XCTAssertEqual(issues, [.missingText(0)])
    }

    /// A STEP WHOSE FIELDS DO NOT MATCH ITS VERB was written by something that
    /// did not understand the verb, and running it would be a guess about
    /// which half was meant.
    func testAStepThatContradictsItselfIsRefused() {
        // A wait that also names a target.
        XCTAssertEqual(
            PageInteractionPlan.validate([
                .init(verb: .wait, target: "Sign in", seconds: 0.5)]),
            [.contradictoryStep(0, .wait)])
        // A press carrying text.
        XCTAssertEqual(
            PageInteractionPlan.validate([
                .init(verb: .press, target: "Sign in", text: "hello")]),
            [.contradictoryStep(0, .press)])
    }

    func testAWaitOutsideItsRangeIsRefused() {
        XCTAssertEqual(
            PageInteractionPlan.validate([.init(verb: .wait, seconds: 30)]),
            [.waitOutOfRange(0, 30)])
        XCTAssertEqual(
            PageInteractionPlan.validate([.init(verb: .wait, seconds: 0)]),
            [.waitOutOfRange(0, 0)])
    }

    func testTextLongerThanAFieldTakesIsRefused() {
        let long = String(repeating: "a", count: PageInteractionPlan.maximumTextBytes + 1)
        let issues = PageInteractionPlan.validate([
            .init(verb: .fill, target: "Notes", text: long)])
        XCTAssertEqual(issues.count, 1)
        guard case .textTooLong = issues[0] else {
            return XCTFail("expected textTooLong, got \(issues[0])")
        }
    }

    /// EVERY ISSUE, NOT THE FIRST. A model correcting one problem per
    /// round-trip takes four turns to write one plan.
    func testEveryProblemIsReportedAtOnce() {
        let issues = PageInteractionPlan.validate([
            .init(verb: .press, target: ""),
            .init(verb: .fill, target: "Email"),
            .init(verb: .wait, seconds: 99),
        ])
        XCTAssertEqual(issues.count, 3)
    }

    // MARK: - The contract the model reads

    /// The authoring contract and the parser must describe the same grammar.
    /// They are written in one file for that reason; this checks the words
    /// actually name the verbs the parser accepts.
    func testTheAuthoringContractNamesEveryVerbTheParserAccepts() {
        let contract = PageInteractionPlan.authoringContract
        for verb in PageInteractionStep.Verb.allCases {
            XCTAssertTrue(
                contract.contains(verb.rawValue),
                "the contract never mentions \(verb.rawValue), so the model will not use it")
        }
        XCTAssertTrue(contract.contains("\(PageInteractionPlan.maximumSteps)"))
    }
}

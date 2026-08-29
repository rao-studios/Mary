//
//  WebArrivalTests.swift
//  MaryPluginTests
//
//  Pins what Mary thinks she has arrived at.
//
//  THE FAILURE THIS GUARDS AGAINST DOES NOT LOOK LIKE A FAILURE. A bot check
//  and a consent wall both present as an ordinary page — a title, a web area,
//  text, controls — so every reader downstream returns something true and
//  useless: "there's nothing on that page I can press." The user goes off to
//  debug a site's layout, and the site never did anything.
//
//  Both halves are therefore about FALSE POSITIVES as much as detection. A
//  check that fired on any page mentioning cookies would be worse than no
//  check at all, because it would refuse pages that were perfectly fine.
//

import ApplicationServices
import XCTest
@testable import MaryPlugin

final class WebArrivalTests: XCTestCase {

    /// The tests below are about labels and text, never about a live tree, so
    /// every element shares one throwaway handle.
    private let handle = AXUIElementCreateSystemWide()

    private func control(
        _ label: String, kind: PageElementKind = .button, ordinal: Int = 1
    ) -> PageElement {
        PageElement(
            ordinal: ordinal,
            role: "AXButton",
            kind: kind,
            label: label,
            frame: CGRect(x: 0, y: 0, width: 80, height: 24),
            axElement: handle)
    }

    // MARK: - The bot check

    func testAnInterstitialIsRecognisedByItsServicesWords() {
        XCTAssertTrue(
            WebPageChallenge.isChallenge(
                pageText: "Just a moment…\nVerify you are human"))
    }

    /// ⚠️ THE FALSE POSITIVE THAT MATTERS. An article about bot detection
    /// contains every phrase in the list and is a perfectly good page. The
    /// second condition — an interstitial is nearly empty — is what separates
    /// them, and dropping it would make Mary refuse to read anything written
    /// about CAPTCHAs.
    func testALongPageAboutBotChecksIsNotABotCheck() {
        let article = String(
            repeating: "Sites ask you to verify you are human for many reasons. ",
            count: 60)
        XCTAssertGreaterThan(article.utf8.count, 1500)
        XCTAssertFalse(WebPageChallenge.isChallenge(pageText: article))
    }

    func testAnOrdinaryPageIsNotAChallenge() {
        XCTAssertFalse(
            WebPageChallenge.isChallenge(pageText: "Shader Editor\nCompiled in 0.4 secs"))
    }

    // MARK: - The consent wall

    /// THE SIGNATURE IS THE PAIR, not a keyword and not a page size. A consent
    /// platform must offer a way to refuse, so accept-shaped and refuse-shaped
    /// controls appear together — and that pair is what almost no ordinary
    /// page has.
    func testAcceptAndRejectTogetherIsAConsentWall() {
        let labels = WebArrival.consentWallLabels(among: [
            control("Accept all"),
            control("Reject all", ordinal: 2),
            control("Manage options", ordinal: 3),
        ])
        XCTAssertNotNil(labels)
        XCTAssertTrue(labels?.contains("Accept all") == true)
        XCTAssertTrue(labels?.contains("Reject all") == true)
    }

    /// ⚠️ THE FALSE POSITIVE THAT MATTERS HERE. A checkout, an installer, a
    /// terms page — all have an "Accept" and none is a cookie wall. Without
    /// the refuse-shaped half, Mary would stop and ask a question on every one
    /// of them.
    func testAnAcceptOnItsOwnIsNotAConsentWall() {
        XCTAssertNil(WebArrival.consentWallLabels(among: [
            control("Accept"),
            control("Back", ordinal: 2),
            control("Continue shopping", ordinal: 3),
        ]))
    }

    func testARejectOnItsOwnIsNotAConsentWall() {
        XCTAssertNil(WebArrival.consentWallLabels(among: [
            control("Reject"),
            control("Cancel", ordinal: 2),
        ]))
    }

    func testAPageWithNoControlsIsNotAConsentWall() {
        XCTAssertNil(WebArrival.consentWallLabels(among: []))
    }

    /// A link into the cookie policy begins with the same word and is not the
    /// control. Length is what separates a button from body copy.
    func testProseBeginningWithAConsentWordIsNotAControl() {
        XCTAssertNil(WebArrival.consentWallLabels(among: [
            control(
                "Accept all cookies and similar technologies to help us improve "
                    + "our services and show you advertising that may interest you"),
            control("Reject all", ordinal: 2),
        ]))
    }

    /// A banner commonly renders its buttons twice — once in the dialog and
    /// once in a sticky footer. Naming the same choice twice reads as four
    /// options and makes the sentence nonsense.
    func testRepeatedButtonsAreNamedOnce() {
        let labels = WebArrival.consentWallLabels(among: [
            control("Accept all"),
            control("Reject all", ordinal: 2),
            control("ACCEPT ALL", ordinal: 3),
        ])
        XCTAssertEqual(labels?.count, 2)
    }

    // MARK: - What it says

    /// IT NAMES THE CHOICE, because the useful next thing the user says is one
    /// of these words — and `click_on_page` presses whichever they pick. A
    /// sentence that merely reported an obstacle would leave them nothing to
    /// answer.
    func testTheSentenceNamesTheButtonsAndHandsTheChoiceBack() {
        let sentence = WebArrival.consentSentence(labels: ["Accept all", "Reject all"])
        XCTAssertTrue(sentence.contains("Accept all"))
        XCTAssertTrue(sentence.contains("Reject all"))
        XCTAssertTrue(sentence.lowercased().contains("your call"))
    }

    /// The labels are quoted as the PAGE spelled them, not as this file
    /// lowercased them, so the words the user hears are the words on screen.
    func testTheSentenceQuotesThePagesOwnCapitalisation() {
        let labels = WebArrival.consentWallLabels(among: [
            control("I Accept"), control("Manage Preferences", ordinal: 2),
        ])
        let sentence = WebArrival.consentSentence(labels: labels ?? [])
        XCTAssertTrue(sentence.contains("I Accept"))
        XCTAssertTrue(sentence.contains("Manage Preferences"))
    }
}

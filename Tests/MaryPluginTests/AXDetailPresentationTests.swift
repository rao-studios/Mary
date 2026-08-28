//
//  AXDetailPresentationTests.swift
//  BonniePluginTests
//
//  Pins the reconstruction's arithmetic — the decisions that turn a detail
//  decoration into something drawable, kept on this side of the seam
//  precisely so they can be tested (Clyde has no test target). The rules
//  worth defending: a made-up slider denominator is refused rather than
//  guessed, content beats naming in the text ladder, and a provider color
//  that would be invisible on Clyde's canvas loses to the theme's own.
//

import CoreGraphics
import Foundation
import XCTest
@testable import MaryPlugin

final class AXDetailPresentationTests: XCTestCase {

    // MARK: - Toggle state

    func testToggleStateReadsAXsThreeValues() {
        XCTAssertEqual(AXDetailPresentation.toggleState(numericValue: 0), .off)
        XCTAssertEqual(AXDetailPresentation.toggleState(numericValue: 1), .on)
        XCTAssertEqual(AXDetailPresentation.toggleState(numericValue: 2), .mixed)
    }

    func testAControlThatDeclinedToReportHasNoState() {
        XCTAssertNil(
            AXDetailPresentation.toggleState(numericValue: nil),
            "no state is drawn rather than an 'off' that was never said")
    }

    // MARK: - Slider fraction

    func testTheThumbSitsWhereTheValueFalls() {
        XCTAssertEqual(
            AXDetailPresentation.sliderFraction(value: 5, min: 0, max: 10) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(
            AXDetailPresentation.sliderFraction(value: 0, min: 0, max: 10) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(
            AXDetailPresentation.sliderFraction(value: 10, min: 0, max: 10) ?? -1, 1, accuracy: 0.001)
    }

    func testANonZeroMinimumIsHonoured() {
        XCTAssertEqual(
            AXDetailPresentation.sliderFraction(value: 75, min: 50, max: 100) ?? 0,
            0.5, accuracy: 0.001)
    }

    func testAValueOutsideItsBoundsClampsToTheTrack() {
        XCTAssertEqual(
            AXDetailPresentation.sliderFraction(value: -5, min: 0, max: 10) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(
            AXDetailPresentation.sliderFraction(value: 50, min: 0, max: 10) ?? -1, 1, accuracy: 0.001)
    }

    /// A thumb drawn from an invented denominator looks exactly as
    /// authoritative as a real one — so it is refused.
    func testADegenerateRangeYieldsNoThumbRatherThanAGuess() {
        XCTAssertNil(AXDetailPresentation.sliderFraction(value: 5, min: 10, max: 10))
        XCTAssertNil(AXDetailPresentation.sliderFraction(value: 5, min: 10, max: 0))
        XCTAssertNil(AXDetailPresentation.sliderFraction(value: 5, min: nil, max: 10))
        XCTAssertNil(AXDetailPresentation.sliderFraction(value: 5, min: 0, max: nil))
        XCTAssertNil(AXDetailPresentation.sliderFraction(value: nil, min: 0, max: 10))
        XCTAssertNil(AXDetailPresentation.sliderFraction(value: .nan, min: 0, max: 10))
        XCTAssertNil(AXDetailPresentation.sliderFraction(value: 5, min: 0, max: .infinity))
    }

    // MARK: - Fitted font size

    func testTextIsFittedBelowTheFrameHeight() {
        let size = AXDetailPresentation.fittedFontSize(frameHeight: 20)

        XCTAssertLessThan(size, 20, "ascenders and descenders must fit inside the box")
        XCTAssertGreaterThan(size, 10)
    }

    func testMoreLinesShareTheHeight() {
        let single = AXDetailPresentation.fittedFontSize(frameHeight: 60, lineCount: 1)
        let triple = AXDetailPresentation.fittedFontSize(frameHeight: 60, lineCount: 3)

        XCTAssertEqual(triple, single / 3, accuracy: 0.001)
    }

    func testTheFittedSizeIsBounded() {
        XCTAssertEqual(
            AXDetailPresentation.fittedFontSize(frameHeight: 10_000),
            AXDetailPresentation.maximumFontSize)
        XCTAssertEqual(
            AXDetailPresentation.fittedFontSize(frameHeight: 0.1),
            AXDetailPresentation.minimumFontSize)
        XCTAssertEqual(
            AXDetailPresentation.fittedFontSize(frameHeight: 0),
            AXDetailPresentation.minimumFontSize)
        XCTAssertEqual(
            AXDetailPresentation.fittedFontSize(frameHeight: .nan),
            AXDetailPresentation.minimumFontSize)
        XCTAssertEqual(
            AXDetailPresentation.fittedFontSize(frameHeight: 20, lineCount: 0),
            AXDetailPresentation.fittedFontSize(frameHeight: 20, lineCount: 1),
            "a zero line count cannot divide by zero")
    }

    // MARK: - The display-text ladder

    private func detail(
        textValue: String? = nil, placeholder: String? = nil, help: String? = nil,
        roleDescription: String? = nil
    ) -> AXNodeDetail {
        AXNodeDetail(
            id: AXNodeID(raw: 1), textValue: textValue, placeholder: placeholder,
            help: help, roleDescription: roleDescription)
    }

    /// What is actually on screen beats what the walk's title ladder guessed.
    func testTheValueBeatsTheLabel() {
        let text = AXDetailPresentation.displayText(
            role: "AXStaticText", category: .text, label: "walk guess",
            detail: detail(textValue: "the real words"))

        XCTAssertEqual(text, "the real words")
    }

    func testAnEmptyFieldFallsToItsPlaceholder() {
        let text = AXDetailPresentation.displayText(
            role: "AXTextField", category: .interactive, label: nil,
            detail: detail(placeholder: "Search"))

        XCTAssertEqual(text, "Search")
    }

    func testTheLabelStandsWhenNoValueWasRead() {
        let text = AXDetailPresentation.displayText(
            role: "AXButton", category: .interactive, label: "Commit", detail: nil)

        XCTAssertEqual(text, "Commit")
    }

    /// An image has no value, so its description ladder is the whole story.
    func testAnImageUsesItsDescriptionLadder() {
        XCTAssertEqual(
            AXDetailPresentation.displayText(
                role: "AXImage", category: .image, label: "Avatar", detail: nil),
            "Avatar")
        XCTAssertEqual(
            AXDetailPresentation.displayText(
                role: "AXImage", category: .image, label: nil,
                detail: detail(roleDescription: "image")),
            "image")
        XCTAssertEqual(
            AXDetailPresentation.displayText(
                role: "AXImage", category: .image, label: nil, detail: detail(help: "Profile photo")),
            "Profile photo")
    }

    func testWhitespaceOnlyStringsAreNotText() {
        let text = AXDetailPresentation.displayText(
            role: "AXStaticText", category: .text, label: "Real",
            detail: detail(textValue: "   \n "))

        XCTAssertEqual(text, "Real", "a blank value must not shadow a usable label")
    }

    func testANodeWithNothingToSayHasNoText() {
        XCTAssertNil(
            AXDetailPresentation.displayText(
                role: "AXGroup", category: .container, label: nil, detail: nil))
    }

    func testTheSecurePlaceholderIsBoundedAndNeverEmpty() {
        XCTAssertEqual(AXDetailPresentation.securePlaceholder(characters: 4), "••••")
        XCTAssertEqual(AXDetailPresentation.securePlaceholder(characters: 0).count, 1)
        XCTAssertEqual(AXDetailPresentation.securePlaceholder(characters: 500).count, 32)
    }

    // MARK: - Color usability

    private let white = AXTextRunColor(red: 1, green: 1, blue: 1)
    private let black = AXTextRunColor(red: 0, green: 0, blue: 0)

    func testAColorThatWouldVanishIntoTheCanvasIsRefused() {
        XCTAssertNil(
            AXDetailPresentation.usableForeground(white, onDark: false),
            "white text on Clyde's light canvas is invisible")
        XCTAssertNil(
            AXDetailPresentation.usableForeground(black, onDark: true),
            "black text on Clyde's dark canvas is invisible")
    }

    func testAColorThatReadsAgainstTheCanvasSurvives() {
        XCTAssertNotNil(AXDetailPresentation.usableForeground(black, onDark: false))
        XCTAssertNotNil(AXDetailPresentation.usableForeground(white, onDark: true))
    }

    func testANearlyTransparentColorIsRefused() {
        let ghost = AXTextRunColor(red: 0, green: 0, blue: 0, alpha: 0.1)
        XCTAssertNil(AXDetailPresentation.usableForeground(ghost, onDark: false))
    }

    func testNoColorAtAllStaysNil() {
        XCTAssertNil(AXDetailPresentation.usableForeground(nil, onDark: false))
    }

    func testLuminanceWeightsGreenMostHeavily() {
        let green = AXTextRunColor(red: 0, green: 1, blue: 0)
        let blue = AXTextRunColor(red: 0, green: 0, blue: 1)

        XCTAssertGreaterThan(
            AXDetailPresentation.luminance(green), AXDetailPresentation.luminance(blue))
        XCTAssertEqual(AXDetailPresentation.luminance(self.white), 1, accuracy: 0.001)
        XCTAssertEqual(AXDetailPresentation.luminance(self.black), 0, accuracy: 0.001)
    }

    // MARK: - Track axis

    func testTheTrackRunsAlongTheLongAxis() {
        XCTAssertTrue(
            AXDetailPresentation.isHorizontal(CGRect(x: 0, y: 0, width: 200, height: 12)))
        XCTAssertFalse(
            AXDetailPresentation.isHorizontal(CGRect(x: 0, y: 0, width: 12, height: 200)))
        XCTAssertTrue(
            AXDetailPresentation.isHorizontal(CGRect(x: 0, y: 0, width: 20, height: 20)),
            "a square control defaults to the shape nearly every real one has")
    }
}

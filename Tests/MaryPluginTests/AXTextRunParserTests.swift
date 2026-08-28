//
//  AXTextRunParserTests.swift
//  BonniePluginTests
//
//  Pins the attributed-string decode the detail lane's styled reconstruction
//  stands on: AX's own text-attribute keys (NOT AppKit's), `AXFont` as a
//  dictionary AND as a real font object, CGColor conversion into sRGB, the
//  font-name substring inference that is the only weight/slant signal AX
//  offers, and the run cap's coalesce-rather-than-drop rule. Pure: no live
//  AX, no IPC.
//

import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import MaryPlugin

final class AXTextRunParserTests: XCTestCase {

    // The runtime values of the SDK's `Unmanaged<CFString>` text-attribute
    // constants, spelled out here so a test failure names the actual key
    // rather than an opaque constant.
    private let fontKey = NSAttributedString.Key("AXFont")
    private let foregroundKey = NSAttributedString.Key("AXForegroundColor")
    private let backgroundKey = NSAttributedString.Key("AXBackgroundColor")
    private let underlineKey = NSAttributedString.Key("AXUnderline")
    private let strikethroughKey = NSAttributedString.Key("AXStrikethrough")

    private func fontDictionary(
        name: String? = nil, family: String? = nil, size: Double? = nil
    ) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        if let name { dictionary["AXFontName"] = name }
        if let family { dictionary["AXFontFamily"] = family }
        if let size { dictionary["AXFontSize"] = NSNumber(value: size) }
        return dictionary
    }

    // MARK: - The AX keys, and the font shapes

    func testAFontDictionaryYieldsNameFamilyAndSize() {
        let attributed = NSAttributedString(
            string: "Hello",
            attributes: [fontKey: fontDictionary(name: "Helvetica-Bold", family: "Helvetica", size: 13)])

        let runs = AXTextRunParser.runs(from: attributed, runCap: 8)

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.text, "Hello")
        XCTAssertEqual(runs.first?.fontName, "Helvetica-Bold")
        XCTAssertEqual(runs.first?.fontFamily, "Helvetica")
        XCTAssertEqual(runs.first?.fontSize, 13)
        XCTAssertEqual(runs.first?.isBold, true)
    }

    /// Some providers hand back a real font object where the documented
    /// shape is a dictionary; both must decode.
    func testARealNSFontValueDecodesToo() {
        let font = NSFont(name: "Times-Italic", size: 18) ?? NSFont.systemFont(ofSize: 18)
        let attributed = NSAttributedString(string: "Serif", attributes: [fontKey: font])

        let runs = AXTextRunParser.runs(from: attributed, runCap: 8)

        XCTAssertEqual(runs.first?.fontSize, 18)
        XCTAssertNotNil(runs.first?.fontName)
    }

    /// The failure this file exists to prevent: AppKit's `.font` key is NOT
    /// what AX answers with, and reading it would leave every run unstyled.
    func testAppKitsOwnFontKeyIsNotWhatAXAnswersWith() {
        let attributed = NSAttributedString(
            string: "Plain", attributes: [.font: NSFont.systemFont(ofSize: 12)])

        let runs = AXTextRunParser.runs(from: attributed, runCap: 8)

        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs.first?.fontSize, "AppKit's .font key must not be mistaken for AXFont")
    }

    // MARK: - Run segmentation

    func testEachStyledSliceBecomesItsOwnRunInOrder() {
        let attributed = NSMutableAttributedString(
            string: "Bold",
            attributes: [fontKey: fontDictionary(name: "Helvetica-Bold", size: 12)])
        attributed.append(
            NSAttributedString(
                string: "plain",
                attributes: [fontKey: fontDictionary(name: "Helvetica", size: 12)]))

        let runs = AXTextRunParser.runs(from: attributed, runCap: 8)

        XCTAssertEqual(runs.map(\.text), ["Bold", "plain"])
        XCTAssertEqual(runs.map(\.isBold), [true, false])
    }

    func testEmptyInputYieldsNoRuns() {
        XCTAssertTrue(AXTextRunParser.runs(from: NSAttributedString(string: ""), runCap: 8).isEmpty)
    }

    func testAZeroRunCapYieldsNoRuns() {
        let attributed = NSAttributedString(string: "text")
        XCTAssertTrue(AXTextRunParser.runs(from: attributed, runCap: 0).isEmpty)
    }

    /// Past the cap the tail keeps its TEXT and loses only its styling —
    /// a reconstruction that drops the end of a paragraph would be lying
    /// about the content, which is the worse failure.
    func testRunsPastTheCapCoalesceIntoOneUnstyledTailRatherThanVanishing() {
        let attributed = NSMutableAttributedString()
        for index in 0..<6 {
            attributed.append(
                NSAttributedString(
                    string: "s\(index)",
                    attributes: [fontKey: fontDictionary(name: "Font-\(index)", size: Double(10 + index))]))
        }

        let runs = AXTextRunParser.runs(from: attributed, runCap: 3)

        XCTAssertEqual(runs.count, 4, "3 styled runs plus one coalesced tail")
        XCTAssertEqual(runs.prefix(3).map(\.text), ["s0", "s1", "s2"])
        XCTAssertEqual(runs.last?.text, "s3s4s5")
        XCTAssertNil(runs.last?.fontName, "the coalesced tail carries no styling")
        XCTAssertEqual(
            runs.map(\.text).joined(), "s0s1s2s3s4s5", "no character is ever dropped")
    }

    // MARK: - Colors

    func testAnSRGBColorDecodesToItsComponents() {
        let color = CGColor(srgbRed: 1, green: 0.5, blue: 0.25, alpha: 0.8)
        let attributed = NSAttributedString(string: "c", attributes: [foregroundKey: color])

        let runs = AXTextRunParser.runs(from: attributed, runCap: 8)

        let foreground = try? XCTUnwrap(runs.first?.foreground)
        XCTAssertEqual(foreground?.red ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(foreground?.green ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(foreground?.blue ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(foreground?.alpha ?? 0, 0.8, accuracy: 0.001)
    }

    /// A provider drawing in a non-sRGB space must still yield comparable
    /// numbers — that conversion is what makes two apps' colors mean the
    /// same thing.
    func testANonSRGBColorIsConvertedRatherThanRefused() {
        let gray = CGColor(gray: 0.5, alpha: 1)
        let attributed = NSAttributedString(string: "g", attributes: [backgroundKey: gray])

        let runs = AXTextRunParser.runs(from: attributed, runCap: 8)

        let background = runs.first?.background
        XCTAssertNotNil(background, "a gray-space color must convert, not decline")
        XCTAssertEqual(background?.alpha ?? 0, 1, accuracy: 0.001)
    }

    func testANonColorValueUnderAColorKeyIsDeclined() {
        let attributed = NSAttributedString(string: "x", attributes: [foregroundKey: "not a color"])
        XCTAssertNil(AXTextRunParser.runs(from: attributed, runCap: 8).first?.foreground)
    }

    // MARK: - Underline / strikethrough, both shapes

    func testUnderlineAndStrikethroughAcceptBooleanOrStyleNumber() {
        let boolean = NSAttributedString(
            string: "u", attributes: [underlineKey: true, strikethroughKey: true])
        let numeric = NSAttributedString(
            string: "u",
            attributes: [
                underlineKey: NSNumber(value: NSUnderlineStyle.single.rawValue),
                strikethroughKey: NSNumber(value: 2),
            ])

        for attributed in [boolean, numeric] {
            let run = AXTextRunParser.runs(from: attributed, runCap: 8).first
            XCTAssertEqual(run?.isUnderlined, true)
            XCTAssertEqual(run?.isStrikethrough, true)
        }
    }

    func testAZeroStyleNumberIsNotSet() {
        let attributed = NSAttributedString(
            string: "u", attributes: [underlineKey: NSNumber(value: 0), strikethroughKey: false])
        let run = AXTextRunParser.runs(from: attributed, runCap: 8).first
        XCTAssertEqual(run?.isUnderlined, false)
        XCTAssertEqual(run?.isStrikethrough, false)
    }

    // MARK: - Weight and slant inference

    func testBoldAndItalicAreInferredFromThePostScriptName() {
        let bold = ["Helvetica-Bold", "SFPro-Semibold", "Avenir-Black", "Inter-Heavy", "X-Medium"]
        for name in bold {
            XCTAssertTrue(AXTextRunParser.isBold(fontName: name), "\(name) should read as bold")
        }

        let notBold = ["Helvetica", "Times-Roman", ".SFNS-Regular", "Courier-Light"]
        for name in notBold {
            XCTAssertFalse(AXTextRunParser.isBold(fontName: name), "\(name) should not read as bold")
        }

        for name in ["Times-Italic", "Helvetica-Oblique", "Georgia-BoldItalic"] {
            XCTAssertTrue(AXTextRunParser.isItalic(fontName: name), "\(name) should read as italic")
        }
        for name in ["Times-Roman", "Helvetica-Bold"] {
            XCTAssertFalse(AXTextRunParser.isItalic(fontName: name), "\(name) should not read as italic")
        }
    }

    func testAnAbsentFontNameInfersNeitherWeightNorSlant() {
        XCTAssertFalse(AXTextRunParser.isBold(fontName: nil))
        XCTAssertFalse(AXTextRunParser.isItalic(fontName: nil))
    }

    func testCaseDoesNotChangeTheInference() {
        XCTAssertTrue(AXTextRunParser.isBold(fontName: "HELVETICA-BOLD"))
        XCTAssertTrue(AXTextRunParser.isItalic(fontName: "times-ITALIC"))
    }
}

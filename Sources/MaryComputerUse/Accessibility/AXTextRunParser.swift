//
//  AXTextRunParser.swift
//  MaryComputerUse
//
//  WHAT: NSAttributedString → styled runs. Pure decode, no AX IPC.
//  IN:   kAXAttributedStringForRange (AXFont / AXForegroundColor keys)
//  OUT:  AXDetailReader
//  PIN:  AX keys, not AppKit names. AXFont is a dictionary or an NSFont.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum AXTextRunParser {

    // AX's text-attribute keys, resolved once. They arrive from the SDK as
    // `Unmanaged<CFString>` (unlike the plain attribute names, which are `String`), hence
    // the unwrap; the runtime values are the literals in the trailing comments.
    private static let fontKey = kAXFontTextAttribute.takeUnretainedValue() as String  // AXFont
    private static let foregroundKey =
        kAXForegroundColorTextAttribute.takeUnretainedValue() as String  // AXForegroundColor
    private static let backgroundKey =
        kAXBackgroundColorTextAttribute.takeUnretainedValue() as String  // AXBackgroundColor
    private static let underlineKey =
        kAXUnderlineTextAttribute.takeUnretainedValue() as String  // AXUnderline
    private static let strikethroughKey =
        kAXStrikethroughTextAttribute.takeUnretainedValue() as String  // AXStrikethrough
    private static let fontNameKey = kAXFontNameKey.takeUnretainedValue() as String  // AXFontName
    private static let fontFamilyKey = kAXFontFamilyKey.takeUnretainedValue() as String  // AXFontFamily
    private static let fontSizeKey = kAXFontSizeKey.takeUnretainedValue() as String  // AXFontSize

    /// Split an attributed string into maximal same-styled runs.
    public static func runs(from attributed: NSAttributedString, runCap: Int) -> [AXTextRun] {
        guard runCap > 0, attributed.length > 0 else { return [] }
        var runs: [AXTextRun] = []
        var overflow = ""
        let full = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttributes(in: full, options: []) { attributes, range, _ in
            let text = attributed.attributedSubstring(from: range).string
            guard !text.isEmpty else { return }
            if runs.count >= runCap {
                overflow += text
                return
            }
            runs.append(run(text: text, attributes: attributes))
        }

        if !overflow.isEmpty {
            runs.append(AXTextRun(text: overflow))
        }
        return runs
    }

    /// One run's worth of decode — the attribute dictionary AX handed back
    /// for a single same-styled range.
    static func run(text: String, attributes: [NSAttributedString.Key: Any]) -> AXTextRun {
        let (name, family, size) = font(from: attributes[NSAttributedString.Key(fontKey)])
        return AXTextRun(
            text: text,
            fontName: name,
            fontFamily: family,
            fontSize: size,
            isBold: isBold(fontName: name),
            isItalic: isItalic(fontName: name),
            isUnderlined: isSet(attributes[NSAttributedString.Key(underlineKey)]),
            isStrikethrough: isSet(attributes[NSAttributedString.Key(strikethroughKey)]),
            foreground: color(from: attributes[NSAttributedString.Key(foregroundKey)]),
            background: color(from: attributes[NSAttributedString.Key(backgroundKey)]))
    }

    /// `AXFont` as a dictionary is the documented shape; a real `NSFont` is
    /// the observed one from providers that hand their own object across.
    /// Both answer the same three questions.
    private static func font(from value: Any?) -> (name: String?, family: String?, size: Double?) {
        if let dictionary = value as? [String: Any] {
            return (
                dictionary[fontNameKey] as? String,
                dictionary[fontFamilyKey] as? String,
                (dictionary[fontSizeKey] as? NSNumber)?.doubleValue
            )
        }
        if let font = value as? NSFont {
            return (font.fontName, font.familyName, Double(font.pointSize))
        }
        return (nil, nil, nil)
    }

    /// Underline/strikethrough arrive as a boolean or as a style number
    /// depending on the provider; any non-zero number counts as set, which
    /// also makes `NSUnderlineStyle.single.rawValue` read correctly.
    private static func isSet(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        return false
    }

    /// AX colors arrive as `CGColor`, in whatever colorspace the provider drew in.
    static func color(from value: Any?) -> AXTextRunColor? {
        guard let raw = value, CFGetTypeID(raw as CFTypeRef) == CGColor.typeID else { return nil }
        let cgColor = raw as! CGColor
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return nil }
        return AXTextRunColor(
            red: Double(components[0]),
            green: Double(components[1]),
            blue: Double(components[2]),
            alpha: components.count >= 4 ? Double(components[3]) : Double(converted.alpha))
    }

    // AX reports no weight or slant of its own — the font NAME is the only signal, and it
    // is the signal every provider actually fills in.

    private static let boldMarkers = ["bold", "semibold", "demibold", "heavy", "black", "medium"]
    private static let italicMarkers = ["italic", "oblique"]

    static func isBold(fontName: String?) -> Bool {
        guard let lowered = fontName?.lowercased() else { return false }
        // "Semibold"/"Demibold" contain "bold" already; "medium" is the one
        // weight marker that does not, and it is the lightest thing this
        // treats as heavier-than-regular.
        return boldMarkers.contains { lowered.contains($0) }
    }

    static func isItalic(fontName: String?) -> Bool {
        guard let lowered = fontName?.lowercased() else { return false }
        return italicMarkers.contains { lowered.contains($0) }
    }
}

//
//  AXDetailPresentation.swift
//  MaryAdapter
//
//  WHAT: Detail-decoration arithmetic (thumb, mixed, inferred size, pick-string).
//  OUT:  WireframeDetailRenderer (stroke/fill/glyph stay there)
//  PIN:  Decidable here so XCTest can reach it; Clyde has no test target.

import CoreGraphics
import Foundation

public enum AXDetailPresentation {

    /// A checkbox/radio state. AX reports these as a NUMBER, where 2 means
    /// "mixed" — the tri-state a checkbox shows when its children disagree.
    public enum ToggleState: Sendable, Equatable {
        case off
        case on
        case mixed
    }

    /// `nil` when the control declined to report — the renderer then draws
    /// the frame alone rather than inventing an "off" that was never said.
    public static func toggleState(numericValue: Double?) -> ToggleState? {
        guard let numericValue else { return nil }
        if numericValue >= 2 { return .mixed }
        return numericValue >= 1 ? .on : .off
    }

    /// Where along its track a range control sits, 0…1. `nil` on a degenerate range (no
    /// bounds, or max ≤ min).
    public static func sliderFraction(value: Double?, min: Double?, max: Double?) -> Double? {
        guard let value, let min, let max, max > min,
              value.isFinite, min.isFinite, max.isFinite
        else { return nil }
        return Swift.min(1, Swift.max(0, (value - min) / (max - min)))
    }

    /// The font size to draw text at when AX reported none — inferred from the space the
    /// element occupies, since a label that fills its box.
    public static func fittedFontSize(frameHeight: CGFloat, lineCount: Int = 1) -> CGFloat {
        guard frameHeight.isFinite, frameHeight > 0 else { return minimumFontSize }
        let lines = CGFloat(Swift.max(1, lineCount))
        let fitted = frameHeight * 0.72 / lines
        return Swift.min(maximumFontSize, Swift.max(minimumFontSize, fitted))
    }

    public static let minimumFontSize: CGFloat = 2
    public static let maximumFontSize: CGFloat = 96

    /// Which string to show for a node, in the order a reader would want it.
    public static func displayText(
        role: String, category: AXNodeCategory, label: String?, detail: AXNodeDetail?
    ) -> String? {
        func nonEmpty(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return text
        }

        if category == .image {
            return nonEmpty(label) ?? nonEmpty(detail?.roleDescription) ?? nonEmpty(detail?.help)
        }
        return nonEmpty(detail?.textValue)
            ?? nonEmpty(label)
            ?? nonEmpty(detail?.placeholder)
            ?? nonEmpty(detail?.help)
    }

    /// The one string a reconstruction of a secure field may ever draw.
    public static func securePlaceholder(characters: Int = 8) -> String {
        String(repeating: "•", count: Swift.max(1, Swift.min(characters, 32)))
    }

    /// Whether a provider's foreground color can be used as-is.
    public static func usableForeground(
        _ color: AXTextRunColor?, onDark: Bool
    ) -> AXTextRunColor? {
        guard let color, color.alpha >= 0.35 else { return nil }
        let contrast = onDark ? luminance(color) : 1 - luminance(color)
        return contrast >= minimumContrast ? color : nil
    }

    /// Rec. 709 relative luminance — the standard weighting, matching how
    /// the eye actually reads brightness.
    static func luminance(_ color: AXTextRunColor) -> Double {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    /// How far a color must sit from the canvas behind it to be kept.
    /// Measured by eye against Clyde's canvas in both themes.
    static let minimumContrast: Double = 0.25

    /// Whether a range control reads as horizontal — the track runs along the element's
    /// LONG axis, the same rule `AXElementRoster` uses to judge a slider's actionable size.
    public static func isHorizontal(_ frame: CGRect) -> Bool {
        frame.width >= frame.height
    }
}

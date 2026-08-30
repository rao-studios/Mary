//
//  AXDetailPresentation.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  THE RECONSTRUCTION'S ARITHMETIC, with no SwiftUI in it. Turning a
//  detail decoration into something drawable asks several questions that
//  are pure functions of the data — where a slider's thumb sits, whether a
//  checkbox reads as mixed, what size text must be to fill a box AX gave no
//  font for, which of several strings is the one worth showing, and whether
//  a color the target app reported can survive on Clyde's own canvas.
//
//  Every one of them lives here rather than in `WireframeDetailRenderer`
//  for the reason `AXHitTest` gives in its header: Clyde has no test target,
//  so anything decidable belongs on this side of the seam where XCTest can
//  reach it. What stays in Clyde is stroke, fill, and glyph — the part that
//  can only be judged by looking.
//

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

    /// Where along its track a range control sits, 0…1.
    ///
    /// `nil` on a degenerate range (no bounds, or max ≤ min) — a thumb drawn
    /// from a made-up denominator is worse than no thumb, because it looks
    /// exactly as authoritative as a real one. A value outside its own
    /// bounds clamps rather than escaping the track.
    public static func sliderFraction(value: Double?, min: Double?, max: Double?) -> Double? {
        guard let value, let min, let max, max > min,
              value.isFinite, min.isFinite, max.isFinite
        else { return nil }
        return Swift.min(1, Swift.max(0, (value - min) / (max - min)))
    }

    /// The font size to draw text at when AX reported none — inferred from
    /// the space the element occupies, since a label that fills its box is
    /// the closest honest guess at what the pixels look like.
    ///
    /// The 0.72 factor is cap-height-ish: text drawn at the full frame
    /// height overflows once ascenders and descenders are counted, and the
    /// result reads as too large next to neighbors whose real sizes AX DID
    /// report.
    public static func fittedFontSize(frameHeight: CGFloat, lineCount: Int = 1) -> CGFloat {
        guard frameHeight.isFinite, frameHeight > 0 else { return minimumFontSize }
        let lines = CGFloat(Swift.max(1, lineCount))
        let fitted = frameHeight * 0.72 / lines
        return Swift.min(maximumFontSize, Swift.max(minimumFontSize, fitted))
    }

    public static let minimumFontSize: CGFloat = 2
    public static let maximumFontSize: CGFloat = 96

    /// Which string to show for a node, in the order a reader would want it.
    ///
    /// Content beats naming: a static text's VALUE is what is on screen,
    /// while its label is at best a repeat of it and at worst the walk's
    /// title-ladder guess. A field with neither shows its placeholder,
    /// which is literally what the pixels show when it is empty. An image
    /// has no value at all, so its description ladder is the only rung.
    /// A secure field is handled before this is ever called.
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
    ///
    /// A color is a claim about the TARGET app's background, not Clyde's:
    /// white-on-dark chrome, rendered onto Clyde's own canvas, becomes
    /// invisible-on-white. `nil` means "fall back to the theme's own text
    /// color", which is always legible, and is far better than a
    /// technically-faithful color no one can see. Nearly-transparent colors
    /// fail the same way.
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

    /// Whether a range control reads as horizontal — the track runs along
    /// the element's LONG axis, the same rule `AXElementRoster` uses to
    /// judge a slider's actionable size. A square-ish control defaults to
    /// horizontal, which is what nearly every real one is.
    public static func isHorizontal(_ frame: CGRect) -> Bool {
        frame.width >= frame.height
    }
}

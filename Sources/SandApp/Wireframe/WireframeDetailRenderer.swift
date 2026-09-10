//
//  WireframeDetailRenderer.swift
//  Sand
//
//  INFERRED VISUAL RECONSTRUCTION — the zoomed half of the wireframe.
//
//  Outside the zoom focus, `WireframeRenderer` draws what it always drew:
//  one stroke per node, an outline of the screen's structure. Inside it,
//  this file draws what those outlines CONTAIN — real text at the size and
//  weight the provider reported (or fitted to its box when it reported
//  none), buttons with their labels, checkboxes showing their state,
//  sliders with the thumb where the value actually sits, fields showing
//  their contents or their placeholder. Every pixel of it comes from
//  Accessibility: no screen recording, no screenshot API, no vision model.
//  The picture is INFERRED from structure and semantics, which is why a
//  canvas full of custom-drawn pixels still reconstructs as its own
//  description and never as a lie about what was rendered.
//
//  The decisions live across the seam in `AXDetailPresentation` (thumb
//  position, fitted size, the text ladder, whether a provider's color
//  survives Sand's canvas) — Sand has no test target, so what can be
//  decided is decided where XCTest can reach it. What stays here is stroke,
//  fill, and glyph: the part only looking can judge.
//

import MaryComputerUse
import SwiftUI

enum WireframeDetailRenderer {

    /// Below this on-screen size, text is a smear rather than a word — and
    /// the whole point of zooming is that things clear this.
    static let minimumReadableSize: CGFloat = 3.5
    /// Padding inside a reconstructed control, in view points.
    static let inset: CGFloat = 2

    static func draw(
        _ node: AXNodeSnapshot,
        detail: AXSubtreeDetail,
        plane: AXDesktopPlane,
        magnification: CGFloat,
        isDark: Bool,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        // The stage's own scale, resolved once: a font size the provider
        // reported is in the TARGET's points, and the reconstruction draws
        // that target scaled into this canvas.
        let scale = plane.fit(into: size).scale
        draw(
            node, detail: detail, plane: plane, scale: scale, isDark: isDark,
            in: &context, size: size)
    }

    private static func draw(
        _ node: AXNodeSnapshot,
        detail: AXSubtreeDetail,
        plane: AXDesktopPlane,
        scale: CGFloat,
        isDark: Bool,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        if let frame = node.frame, frame.width > 0, frame.height > 0 {
            let rect = plane.viewRect(for: frame, in: size)
            reconstruct(
                node, decoration: detail.nodes[node.id], rect: rect,
                scale: scale, isDark: isDark, in: &context)
        }
        for child in node.children {
            draw(
                child, detail: detail, plane: plane, scale: scale,
                isDark: isDark, in: &context, size: size)
        }
    }

    /// One node, drawn as the thing it IS rather than as a rectangle.
    private static func reconstruct(
        _ node: AXNodeSnapshot,
        decoration: AXNodeDetail?,
        rect: CGRect,
        scale: CGFloat,
        isDark: Bool,
        in context: inout GraphicsContext
    ) {
        switch node.role {
        case "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle":
            drawToggle(node, decoration: decoration, rect: rect, scale: scale, isDark: isDark, in: &context)
            return
        case _ where AXDetailReader.rangeRoles.contains(node.role):
            drawRangeControl(node, decoration: decoration, rect: rect, in: &context)
            return
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            drawField(node, decoration: decoration, rect: rect, scale: scale, isDark: isDark, in: &context)
            return
        case "AXButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem":
            drawButton(node, decoration: decoration, rect: rect, scale: scale, isDark: isDark, in: &context)
            return
        case "AXLink":
            drawLink(node, decoration: decoration, rect: rect, scale: scale, in: &context)
            return
        default:
            break
        }

        switch node.category {
        case .text:
            drawText(node, decoration: decoration, rect: rect, scale: scale, isDark: isDark, in: &context)
        case .image:
            drawImagePlaceholder(node, decoration: decoration, rect: rect, in: &context)
        case .interactive:
            drawButton(node, decoration: decoration, rect: rect, scale: scale, isDark: isDark, in: &context)
        case .scrollArea:
            context.stroke(
                Path(rect), with: .color(.teal.opacity(0.35)),
                style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        case .webArea:
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 2), with: .color(.blue.opacity(0.35)),
                style: StrokeStyle(lineWidth: 0.6))
        case .scripted:
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 2), with: .color(.orange.opacity(0.5)),
                style: StrokeStyle(lineWidth: 0.8, dash: [4, 2]))
        case .container, .window, .other:
            // Structure recedes once its contents are legible: the point of
            // the zoom is the words, not the boxes around them.
            context.stroke(Path(rect), with: .color(.gray.opacity(0.12)), lineWidth: 0.4)
        }
    }

    // MARK: - Text

    private static func drawText(
        _ node: AXNodeSnapshot,
        decoration: AXNodeDetail?,
        rect: CGRect,
        scale: CGFloat,
        isDark: Bool,
        in context: inout GraphicsContext
    ) {
        let runs = decoration?.textRuns ?? []
        if !runs.isEmpty {
            drawRuns(runs, rect: rect, scale: scale, isDark: isDark, in: &context)
            return
        }
        guard let text = AXDetailPresentation.displayText(
            role: node.role, category: node.category, label: node.label, detail: decoration)
        else {
            // Nothing to say: leave the faintest trace that something is
            // here, rather than an empty patch that reads as "nothing here".
            context.stroke(Path(rect), with: .color(.secondary.opacity(0.2)), lineWidth: 0.4)
            return
        }
        let fitted = AXDetailPresentation.fittedFontSize(frameHeight: rect.height)
        drawString(
            text, in: rect, size: fitted, weight: .regular, italic: false,
            color: .primary.opacity(0.85), in: &context)
    }

    /// Styled runs, laid out end to end along the element's box. AX gives no
    /// per-run GEOMETRY (`AXBoundsForRange` is not read — see
    /// `AXDetailReader`), so this reconstructs flow rather than typesetting:
    /// runs follow one another and wrap at the box's edge, which is what
    /// makes a bold heading inside a paragraph read as bold in place.
    private static func drawRuns(
        _ runs: [AXTextRun],
        rect: CGRect,
        scale: CGFloat,
        isDark: Bool,
        in context: inout GraphicsContext
    ) {
        var cursor = CGPoint(x: rect.minX + inset, y: rect.minY + inset)
        var lineHeight: CGFloat = 0

        for run in runs {
            let text = run.text.replacingOccurrences(of: "\n", with: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // A reported font size is in the TARGET's points; the stage is
            // drawing that target scaled, so the size scales with it.
            let pointSize = run.fontSize.map { CGFloat($0) * scale }
                ?? AXDetailPresentation.fittedFontSize(frameHeight: rect.height)
            guard pointSize >= minimumReadableSize else { continue }

            let color = AXDetailPresentation.usableForeground(run.foreground, onDark: isDark)
            var styled = Text(text)
                .font(.system(size: pointSize, weight: run.isBold ? .bold : .regular))
                .foregroundColor(color.map(swiftUIColor) ?? .primary.opacity(0.9))
            if run.isItalic { styled = styled.italic() }
            if run.isUnderlined { styled = styled.underline() }
            if run.isStrikethrough { styled = styled.strikethrough() }

            let resolved = context.resolve(styled)
            let measured = resolved.measure(in: CGSize(width: rect.width, height: rect.height))
            // Wrap at the box edge; stop once the box is full, rather than
            // spilling a paragraph over its neighbors.
            if cursor.x > rect.minX + inset, cursor.x + measured.width > rect.maxX - inset {
                cursor.x = rect.minX + inset
                cursor.y += lineHeight
                lineHeight = 0
            }
            guard cursor.y + measured.height <= rect.maxY else { return }

            context.draw(resolved, at: cursor, anchor: .topLeading)
            cursor.x += measured.width
            lineHeight = max(lineHeight, measured.height)
        }
    }

    /// One string, clipped to its box and centered or leading per the shape
    /// of the space it has.
    private static func drawString(
        _ text: String,
        in rect: CGRect,
        size: CGFloat,
        weight: Font.Weight,
        italic: Bool,
        color: Color,
        centered: Bool = false,
        in context: inout GraphicsContext
    ) {
        guard size >= minimumReadableSize, rect.width > 2 else { return }
        var styled = Text(text).font(.system(size: size, weight: weight)).foregroundColor(color)
        if italic { styled = styled.italic() }

        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.draw(
            styled,
            at: centered
                ? CGPoint(x: rect.midX, y: rect.midY)
                : CGPoint(x: rect.minX + inset, y: rect.midY),
            anchor: centered ? .center : .leading)
    }

    // MARK: - Controls

    private static func drawButton(
        _ node: AXNodeSnapshot,
        decoration: AXNodeDetail?,
        rect: CGRect,
        scale: CGFloat,
        isDark: Bool,
        in context: inout GraphicsContext
    ) {
        let enabled = node.isEnabled
        let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.height / 3))
        context.fill(shape, with: .color(.primary.opacity(enabled ? 0.06 : 0.03)))
        context.stroke(
            shape,
            with: .color((node.isFocused ? Color.yellow : .accentColor).opacity(enabled ? 0.8 : 0.35)),
            lineWidth: 1)

        guard let text = AXDetailPresentation.displayText(
            role: node.role, category: node.category, label: node.label, detail: decoration)
        else { return }
        // A popup shows a chevron because that is what a popup looks like —
        // the affordance is part of the reconstruction, not decoration.
        let isPopup = node.role == "AXPopUpButton" || node.role == "AXMenuButton"
        let labelRect = isPopup
            ? rect.insetBy(dx: inset, dy: 0).divided(atDistance: rect.width - 10, from: .minXEdge).slice
            : rect.insetBy(dx: inset, dy: 0)
        drawString(
            text, in: labelRect,
            size: AXDetailPresentation.fittedFontSize(frameHeight: rect.height),
            weight: .medium, italic: false,
            color: .primary.opacity(enabled ? 0.9 : 0.4),
            centered: !isPopup, in: &context)

        if isPopup, rect.width > 16, rect.height > 6 {
            var chevron = Path()
            let x = rect.maxX - 7
            let y = rect.midY
            chevron.move(to: CGPoint(x: x - 3, y: y - 1.5))
            chevron.addLine(to: CGPoint(x: x, y: y + 1.5))
            chevron.addLine(to: CGPoint(x: x + 3, y: y - 1.5))
            context.stroke(chevron, with: .color(.primary.opacity(0.6)), lineWidth: 1)
        }
    }

    private static func drawToggle(
        _ node: AXNodeSnapshot,
        decoration: AXNodeDetail?,
        rect: CGRect,
        scale: CGFloat,
        isDark: Bool,
        in context: inout GraphicsContext
    ) {
        let side = min(rect.height, min(rect.width, 14))
        let box = CGRect(
            x: rect.minX, y: rect.midY - side / 2, width: side, height: side)
        let isRadio = node.role == "AXRadioButton"
        let shape = isRadio
            ? Path(ellipseIn: box)
            : Path(roundedRect: box, cornerRadius: 2)

        let state = AXDetailPresentation.toggleState(numericValue: decoration?.numericValue)
        switch state {
        case .on:
            context.fill(shape, with: .color(.accentColor.opacity(0.85)))
            drawCheckmark(in: box, in: &context)
        case .mixed:
            context.fill(shape, with: .color(.accentColor.opacity(0.55)))
            var dash = Path()
            dash.move(to: CGPoint(x: box.minX + side * 0.25, y: box.midY))
            dash.addLine(to: CGPoint(x: box.maxX - side * 0.25, y: box.midY))
            context.stroke(dash, with: .color(.white), lineWidth: max(1, side * 0.12))
        case .off:
            context.stroke(shape, with: .color(.primary.opacity(0.5)), lineWidth: 1)
        case nil:
            // The control declined to report — an empty box states exactly
            // that, where a drawn "off" would be an invention.
            context.stroke(
                shape, with: .color(.primary.opacity(0.25)),
                style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
        }

        guard let text = AXDetailPresentation.displayText(
            role: node.role, category: node.category, label: node.label, detail: decoration),
            rect.width > side + 6
        else { return }
        let labelRect = CGRect(
            x: box.maxX + 3, y: rect.minY, width: rect.maxX - box.maxX - 3, height: rect.height)
        drawString(
            text, in: labelRect,
            size: AXDetailPresentation.fittedFontSize(frameHeight: rect.height),
            weight: .regular, italic: false, color: .primary.opacity(0.85), in: &context)
    }

    private static func drawCheckmark(in box: CGRect, in context: inout GraphicsContext) {
        guard box.width >= 5 else { return }
        var mark = Path()
        mark.move(to: CGPoint(x: box.minX + box.width * 0.24, y: box.midY))
        mark.addLine(to: CGPoint(x: box.minX + box.width * 0.44, y: box.maxY - box.height * 0.27))
        mark.addLine(to: CGPoint(x: box.maxX - box.width * 0.2, y: box.minY + box.height * 0.28))
        context.stroke(
            mark, with: .color(.white),
            style: StrokeStyle(lineWidth: max(1, box.width * 0.13), lineCap: .round, lineJoin: .round))
    }

    private static func drawRangeControl(
        _ node: AXNodeSnapshot,
        decoration: AXNodeDetail?,
        rect: CGRect,
        in context: inout GraphicsContext
    ) {
        let horizontal = AXDetailPresentation.isHorizontal(rect)
        let thickness = max(2, min(4, (horizontal ? rect.height : rect.width) * 0.3))
        let track = horizontal
            ? CGRect(x: rect.minX, y: rect.midY - thickness / 2, width: rect.width, height: thickness)
            : CGRect(x: rect.midX - thickness / 2, y: rect.minY, width: thickness, height: rect.height)
        let trackShape = Path(roundedRect: track, cornerRadius: thickness / 2)
        context.fill(trackShape, with: .color(.primary.opacity(0.15)))

        guard let fraction = AXDetailPresentation.sliderFraction(
            value: decoration?.numericValue,
            min: decoration?.minimumValue,
            max: decoration?.maximumValue)
        else {
            // No trustworthy denominator: the track alone, with no thumb
            // claiming a position nobody reported.
            context.stroke(trackShape, with: .color(.primary.opacity(0.3)), lineWidth: 0.6)
            return
        }

        // The filled portion reads as progress; the thumb reads as a slider.
        // Both are the same fraction, so one drawing serves both.
        let filled = horizontal
            ? CGRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
            : CGRect(
                x: track.minX, y: track.maxY - track.height * fraction,
                width: track.width, height: track.height * fraction)
        context.fill(
            Path(roundedRect: filled, cornerRadius: thickness / 2),
            with: .color(.accentColor.opacity(0.7)))

        if node.role == "AXSlider" || node.role == "AXScrollBar" {
            let radius = max(2.5, min(6, (horizontal ? rect.height : rect.width) / 2))
            let centre = horizontal
                ? CGPoint(x: track.minX + track.width * fraction, y: track.midY)
                : CGPoint(x: track.midX, y: track.maxY - track.height * fraction)
            let thumb = Path(
                ellipseIn: CGRect(
                    x: centre.x - radius, y: centre.y - radius,
                    width: radius * 2, height: radius * 2))
            context.fill(thumb, with: .color(.accentColor))
            context.stroke(thumb, with: .color(.primary.opacity(0.4)), lineWidth: 0.6)
        }
    }

    private static func drawField(
        _ node: AXNodeSnapshot,
        decoration: AXNodeDetail?,
        rect: CGRect,
        scale: CGFloat,
        isDark: Bool,
        in context: inout GraphicsContext
    ) {
        let shape = Path(roundedRect: rect, cornerRadius: min(3, rect.height / 4))
        context.fill(shape, with: .color(.primary.opacity(0.04)))
        context.stroke(
            shape,
            with: .color((node.isFocused ? Color.yellow : .secondary).opacity(node.isFocused ? 0.9 : 0.5)),
            lineWidth: node.isFocused ? 1.2 : 0.8)

        let interior = rect.insetBy(dx: inset + 1, dy: inset)
        guard interior.width > 2, interior.height > 2 else { return }

        // A password field reconstructs as dots — never as its contents,
        // which the detail lane refuses to read in the first place.
        if AXDetailReader.isSecure(role: node.role, subrole: node.subrole) {
            drawString(
                AXDetailPresentation.securePlaceholder(), in: interior,
                size: AXDetailPresentation.fittedFontSize(frameHeight: rect.height),
                weight: .regular, italic: false, color: .primary.opacity(0.6), in: &context)
            return
        }

        let runs = decoration?.textRuns ?? []
        if !runs.isEmpty {
            drawRuns(runs, rect: interior, scale: scale, isDark: isDark, in: &context)
            return
        }
        if let value = decoration?.textValue ?? node.label, !value.isEmpty {
            drawString(
                value, in: interior,
                size: AXDetailPresentation.fittedFontSize(frameHeight: rect.height),
                weight: .regular, italic: false, color: .primary.opacity(0.9), in: &context)
        } else if let placeholder = decoration?.placeholder {
            // Italic and dimmed, exactly as an empty field renders it.
            drawString(
                placeholder, in: interior,
                size: AXDetailPresentation.fittedFontSize(frameHeight: rect.height),
                weight: .regular, italic: true, color: .secondary.opacity(0.7), in: &context)
        }
    }

    private static func drawLink(
        _ node: AXNodeSnapshot,
        decoration: AXNodeDetail?,
        rect: CGRect,
        scale: CGFloat,
        in context: inout GraphicsContext
    ) {
        guard let text = AXDetailPresentation.displayText(
            role: node.role, category: node.category, label: node.label, detail: decoration)
        else {
            context.stroke(Path(rect), with: .color(.blue.opacity(0.4)), lineWidth: 0.6)
            return
        }
        let size = AXDetailPresentation.fittedFontSize(frameHeight: rect.height)
        guard size >= minimumReadableSize else { return }
        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.draw(
            Text(text).font(.system(size: size)).underline().foregroundColor(.blue),
            at: CGPoint(x: rect.minX + inset, y: rect.midY), anchor: .leading)
    }

    private static func drawImagePlaceholder(
        _ node: AXNodeSnapshot,
        decoration: AXNodeDetail?,
        rect: CGRect,
        in context: inout GraphicsContext
    ) {
        // The cross stays: it is the provenance marker that says "a
        // placeholder stands here", never "these are the pixels". An image
        // is the one thing this reconstruction genuinely cannot see, and
        // saying so plainly is the honest rendering.
        context.fill(Path(rect), with: .color(.purple.opacity(0.06)))
        context.stroke(Path(rect), with: .color(.purple.opacity(0.6)), lineWidth: 0.8)
        var cross = Path()
        cross.move(to: CGPoint(x: rect.minX, y: rect.minY))
        cross.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        cross.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        cross.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        context.stroke(cross, with: .color(.purple.opacity(0.3)), lineWidth: 0.5)

        guard let text = AXDetailPresentation.displayText(
            role: node.role, category: .image, label: node.label, detail: decoration),
            rect.height >= 8
        else { return }
        drawString(
            text, in: rect.insetBy(dx: inset, dy: inset),
            size: min(11, AXDetailPresentation.fittedFontSize(frameHeight: rect.height)),
            weight: .regular, italic: false, color: .purple.opacity(0.9),
            centered: true, in: &context)
    }

    private static func swiftUIColor(_ color: AXTextRunColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

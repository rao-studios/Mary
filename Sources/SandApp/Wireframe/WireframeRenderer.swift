//
//  WireframeRenderer.swift
//  Sand
//
//  Pure draw-command mapping from an AXAppSnapshot onto a Canvas
//  GraphicsContext — category → stroke style, nothing else. Kept separate
//  from WireframeStageView so the category→style table reads as one small
//  function.
//
//  SCALE-AWARE STROKES (2026-08-26, click-to-zoom). Measured against
//  GitHub Desktop at the full-desktop view: its real content — nested
//  `AXGroup` wrappers and `AXStaticText`, the hallmark of a React-shaped
//  DOM — is almost entirely `.container`/`.text`, drawn at 25–60% opacity
//  and a 0.4–0.5pt stroke. At the ~0.3× a two-screen desktop imposes on a
//  960pt-wide window, those strokes round to nothing under anti-aliasing —
//  the tree was walked completely (confirmed live: 129 web nodes, zero
//  truncation), but nothing legible was left to draw. `magnification`
//  (`WireframeViewModel`, the ratio of the current click-to-zoom focus's
//  area to the full desktop's) restores exactly that content as the user
//  zooms in: `.container`/`.text` grow more opaque and slightly heavier,
//  and the label-visibility threshold shrinks, so a zoomed-in region
//  becomes as legible as an `.interactive`-heavy one already was. The
//  bold categories (`.interactive`, `.image`, `.webArea`, `.scripted`)
//  don't need it and are left at their fixed values on purpose — they were
//  never the illegible ones.
//

import MaryComputerUse
import SwiftUI

enum WireframeRenderer {

    /// The minimum on-screen size (in VIEW points, post-scale) a node needs
    /// before its label is drawn — otherwise a dense tree turns into an
    /// unreadable smear of overlapping text. Divided by `magnification` at
    /// draw time; `minimumLabelThreshold` is the floor that division is
    /// clamped to, so extreme zoom still can't flood the stage with labels
    /// for genuinely tiny nodes.
    static let labelSizeThreshold: CGFloat = 28
    static let labelHeightThreshold: CGFloat = 12
    static let minimumLabelWidthThreshold: CGFloat = 6
    static let minimumLabelHeightThreshold: CGFloat = 4

    static func draw(
        snapshot: AXAppSnapshot,
        plane: AXDesktopPlane,
        magnification: CGFloat = 1,
        detail: AXSubtreeDetail? = nil,
        isDark: Bool = false,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        // Faint outlines for every physical screen, so the wireframe reads
        // as "somewhere on the desktop" rather than floating in a void.
        // (Once zoomed well inside one window these may fall entirely off
        // the visible canvas — that costs nothing, so no special-casing.)
        for screen in plane.screenBounds {
            let rect = plane.viewRect(for: screen, in: size)
            context.stroke(
                Path(rect), with: .color(.secondary.opacity(0.25)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }

        // Front-to-back in AX order; draw back windows first so the front
        // window's emphasis paints on top.
        for (index, window) in snapshot.windows.enumerated().reversed() {
            drawWindow(
                window, isFrontmost: index == 0, plane: plane, magnification: magnification,
                detail: detail, isDark: isDark, in: &context, size: size)
        }
    }

    private static func drawWindow(
        _ window: AXWindowSnapshot,
        isFrontmost: Bool,
        plane: AXDesktopPlane,
        magnification: CGFloat,
        detail: AXSubtreeDetail?,
        isDark: Bool,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let frame = window.frame else { return }
        let rect = plane.viewRect(for: frame, in: size)
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 4),
            with: .color(isFrontmost ? .accentColor : .secondary),
            style: StrokeStyle(lineWidth: isFrontmost ? 2 : 1))

        if !window.title.isEmpty {
            context.draw(
                Text(window.title).font(.caption.bold()),
                at: CGPoint(x: rect.minX + 6, y: rect.minY - 8),
                anchor: .topLeading)
        }

        guard let root = window.root else { return }
        drawNode(
            root, plane: plane, magnification: magnification, detail: detail, isDark: isDark,
            in: &context, size: size)
    }

    private static func drawNode(
        _ node: AXNodeSnapshot,
        plane: AXDesktopPlane,
        magnification: CGFloat,
        detail: AXSubtreeDetail?,
        isDark: Bool,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        // THE HANDOFF. At the zoomed-in node, the reconstruction takes over
        // the whole subtree and the wireframe pass stops descending: inside
        // the focus the user gets contents, outside it they keep the
        // structural outline that says where they are.
        if let detail, node.id == detail.rootID {
            WireframeDetailRenderer.draw(
                node, detail: detail, plane: plane, magnification: magnification,
                isDark: isDark, in: &context, size: size)
            return
        }
        if let frame = node.frame, frame.width > 0, frame.height > 0 {
            let rect = plane.viewRect(for: frame, in: size)
            draw(node, rect: rect, magnification: magnification, in: &context)
        }
        for child in node.children {
            drawNode(
                child, plane: plane, magnification: magnification, detail: detail,
                isDark: isDark, in: &context, size: size)
        }
    }

    /// `.container`/`.text` grow more opaque and slightly heavier as
    /// `magnification` climbs, capped well short of the bold categories'
    /// fixed values — see the file header. `sqrt` gives a ramp that reads
    /// as "coming into focus" rather than snapping suddenly legible.
    private static func scaled(
        _ base: CGFloat, magnification: CGFloat, ceiling: CGFloat
    ) -> CGFloat {
        min(base * magnification.squareRoot(), ceiling)
    }

    private static func draw(
        _ node: AXNodeSnapshot, rect: CGRect, magnification: CGFloat,
        in context: inout GraphicsContext
    ) {
        switch node.category {
        case .interactive:
            let color: Color = node.isFocused ? .yellow : .accentColor
            if node.isFocused {
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.15)))
            }
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 2), with: .color(color),
                style: StrokeStyle(lineWidth: node.isEnabled ? 1.2 : 0.6))
        case .text:
            context.stroke(
                Path(rect),
                with: .color(.secondary.opacity(scaled(0.6, magnification: magnification, ceiling: 0.95))),
                lineWidth: scaled(0.5, magnification: magnification, ceiling: 1.3))
        case .image:
            context.stroke(Path(rect), with: .color(.purple.opacity(0.7)), lineWidth: 0.8)
            var cross = Path()
            cross.move(to: CGPoint(x: rect.minX, y: rect.minY))
            cross.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            cross.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            cross.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.stroke(cross, with: .color(.purple.opacity(0.4)), lineWidth: 0.5)
        case .scrollArea:
            context.stroke(
                Path(rect), with: .color(.teal.opacity(0.6)),
                style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        case .webArea:
            // The page boundary — solid where a scroll area is dashed, so
            // "where does the web content start" is answerable at a glance
            // in a browser or Electron window full of native chrome.
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 2), with: .color(.blue.opacity(0.7)),
                style: StrokeStyle(lineWidth: 1))
        case .scripted:
            // Scripted synthesis, not walked AX — dashed orange declares the
            // provenance at a glance, and never resembles a real AX stroke.
            if node.isFocused {
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(.orange.opacity(0.15)))
            }
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 2),
                with: .color(.orange.opacity(node.isEnabled ? 0.8 : 0.4)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
        case .container:
            context.stroke(
                Path(rect),
                with: .color(.gray.opacity(scaled(0.25, magnification: magnification, ceiling: 0.85))),
                lineWidth: scaled(0.4, magnification: magnification, ceiling: 1.2))
        case .window:
            return
        case .other:
            return
        }

        let widthThreshold = max(
            WireframeRenderer.labelSizeThreshold / magnification, minimumLabelWidthThreshold)
        let heightThreshold = max(
            WireframeRenderer.labelHeightThreshold / magnification, minimumLabelHeightThreshold)
        guard let label = node.label, !label.isEmpty,
              rect.width >= widthThreshold,
              rect.height >= heightThreshold
        else { return }
        context.draw(
            Text(label).font(.system(size: 9)).foregroundColor(.primary.opacity(0.8)),
            at: CGPoint(x: rect.minX + 3, y: rect.minY + 2),
            anchor: .topLeading)
    }
}

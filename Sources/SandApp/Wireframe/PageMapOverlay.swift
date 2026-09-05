//
//  PageMapOverlay.swift
//  Sand
//
//  WHAT: The page as VisionAX read it, drawn over the AX wireframe.
//  IN:   PageMapProjection.rows (from BrowserEngine.live's last read)
//  OUT:  a third Canvas pass over the same AXDesktopPlane
//  PIN:  TWO READINGS OF ONE SCREEN, ON TOP OF EACH OTHER, AND THAT IS THE POINT. The
//        wireframe underneath is the browser's Accessibility tree — for a web page,
//        almost always a shell with a hole in it. These rows are what the page lane
//        actually resolves against. Where they disagree is exactly where a browsing turn
//        goes wrong, and there is nowhere else in the system you can see it.
//        DRAWN ONLY AFTER A READ THAT HAPPENED. Nothing here polls, perceives or
//        schedules: the rows come from the engine's own last read, dispatched through
//        the runtime like any other skill. Pixels are read when a skill asks.
//        COLOUR IS THE ONLY OPINION THIS FILE HAS. Which rows, what they are called and
//        what the caption claims are decided in `PageMapProjection`, where they can be
//        tested — see its PIN.
//
import MaryComputerUse
import MaryPlugin
import SwiftUI

enum PageMapOverlay {

    /// What each affordance is drawn in. Green presses, blue fills, orange adjusts,
    /// grey for a row the reading could not offer.
    static func color(for affordance: SeenAffordance) -> Color {
        switch affordance {
        case .press: return .green
        case .fill: return .blue
        case .adjust: return .orange
        case .scroll: return .purple
        case .none: return .gray
        }
    }

    static func draw(
        rows: [PageMapRow],
        caption: String?,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for row in rows {
            let color = color(for: row.affordance)
            // A ROW WITHOUT A REAL NAME IS DASHED. Nothing can be asked for by a name
            // the reading invented, so it must not look like the rows that can.
            context.stroke(
                Path(roundedRect: row.rect, cornerRadius: 2),
                with: .color(color.opacity(row.isNamed ? 0.9 : 0.45)),
                style: StrokeStyle(lineWidth: 1, dash: row.isNamed ? [] : [3, 2]))
            context.fill(
                Path(roundedRect: row.rect, cornerRadius: 2),
                with: .color(color.opacity(0.07)))
            drawLabel(row, color: color, in: &context)
        }
        guard let caption else { return }
        context.draw(
            Text(caption).font(.system(size: 10, weight: .semibold))
                .foregroundColor(.primary),
            at: CGPoint(x: 8, y: size.height - 8),
            anchor: .bottomLeading)
    }

    /// A row narrower than this cannot hold even an ordinal without painting over its
    /// neighbours. MEASURED, NOT GUESSED: a whole page at desktop zoom is a hundred and
    /// fifty rows a few points wide, and drawing a number on each turned the stage into
    /// a field of digits with the wireframe invisible underneath. Zoom in and the same
    /// rows earn their labels back.
    private static let ordinalFloor = CGSize(width: 18, height: 10)
    /// And this much before the NAME fits beside the ordinal.
    private static let nameFloor: CGFloat = 70

    private static func drawLabel(
        _ row: PageMapRow, color: Color, in context: inout GraphicsContext
    ) {
        guard row.rect.width >= ordinalFloor.width,
              row.rect.height >= ordinalFloor.height
        else { return }
        // The ordinal is what the listing SPOKE — it is what a person types back at
        // Mary — so it goes first, and the name only when there is room for it.
        let text = row.rect.width >= nameFloor
            ? "\(row.id) \(shortened(row.label))"
            : "\(row.id)"
        context.draw(
            Text(text).font(.system(size: 9))
                .foregroundColor(color.opacity(row.isNamed ? 1 : 0.6)),
            at: CGPoint(x: row.rect.minX + 2, y: row.rect.minY + 1),
            anchor: .topLeading)
    }

    /// Long enough to recognize, short enough that a paragraph-sized row does not paint
    /// over the three rows beneath it.
    private static func shortened(_ label: String, limit: Int = 28) -> String {
        label.count <= limit ? label : String(label.prefix(limit - 1)) + "…"
    }
}

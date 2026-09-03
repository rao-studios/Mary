//
//  SandStageOverlay.swift
//  Sand
//
//  WHAT: Where the hands went, drawn on top of the wireframe.
//  IN:   SandTraceModel marks (pointer points, the acted element, focus)
//  OUT:  a second Canvas pass over the same AXDesktopPlane
//  PIN:  MARKS ARE EVIDENCE, NOT INTENT. Every point here was parsed from what
//        the machine layer REPORTED it did (`ComputerUseAct.detail`) or from
//        the acted element the runtime recorded — never from what a recipe
//        asked for. A mark that disagrees with the wireframe under it is the
//        most useful thing this app can show, so nothing is snapped or
//        corrected to make them agree.
//        Marks fade with age so a stale click stops competing with a live one.
//
import MaryComputerUse
import SwiftUI

/// One thing worth pointing at, in AX screen coordinates.
struct SandStageMark: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A pointer act — click, move, drag end, scroll.
        case pointer(name: String)
        /// The element the runtime recorded as acted on.
        case acted(label: String)
        /// What claims focus right now.
        case focus(label: String)
    }

    let id: UUID
    let kind: Kind
    /// Present for a pointer mark.
    var point: CGPoint?
    /// Present for an element mark.
    var rect: CGRect?
    let at: Date

    init(
        id: UUID = UUID(), kind: Kind,
        point: CGPoint? = nil, rect: CGRect? = nil, at: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.point = point
        self.rect = rect
        self.at = at
    }
}

enum SandStageOverlay {

    /// How long a mark stays worth looking at. Long enough to see the step
    /// that just ran, short enough that a five-step recipe does not end as a
    /// wall of crosshairs.
    static let lifetime: TimeInterval = 4

    static func draw(
        marks: [SandStageMark],
        plane: AXDesktopPlane,
        now: Date = Date(),
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        for mark in marks {
            let age = now.timeIntervalSince(mark.at)
            guard age < lifetime else { continue }
            // Linear fade, floored well above invisible: the last second of a
            // mark's life should still read as a mark.
            let opacity = max(0.25, 1 - age / lifetime)
            switch mark.kind {
            case .pointer(let name):
                guard let point = mark.point else { continue }
                drawCrosshair(
                    at: plane.viewRect(
                        for: CGRect(x: point.x, y: point.y, width: 0, height: 0),
                        in: size).origin,
                    label: name, opacity: opacity, in: &context)
            case .acted(let label):
                guard let rect = mark.rect else { continue }
                drawRect(
                    plane.viewRect(for: rect, in: size), label: label,
                    color: .red, dashed: false, opacity: opacity, in: &context)
            case .focus(let label):
                guard let rect = mark.rect else { continue }
                drawRect(
                    plane.viewRect(for: rect, in: size), label: label,
                    color: .yellow, dashed: true, opacity: opacity, in: &context)
            }
        }
    }

    private static func drawCrosshair(
        at point: CGPoint, label: String, opacity: Double,
        in context: inout GraphicsContext
    ) {
        let arm: CGFloat = 9
        var path = Path()
        path.move(to: CGPoint(x: point.x - arm, y: point.y))
        path.addLine(to: CGPoint(x: point.x + arm, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - arm))
        path.addLine(to: CGPoint(x: point.x, y: point.y + arm))
        context.stroke(path, with: .color(.red.opacity(opacity)), lineWidth: 1.5)
        context.stroke(
            Path(ellipseIn: CGRect(
                x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
            with: .color(.red.opacity(opacity)), lineWidth: 1.5)
        context.draw(
            Text(label).font(.system(size: 9, weight: .bold))
                .foregroundColor(.red.opacity(opacity)),
            at: CGPoint(x: point.x + arm + 2, y: point.y - arm),
            anchor: .topLeading)
    }

    private static func drawRect(
        _ rect: CGRect, label: String, color: Color, dashed: Bool,
        opacity: Double, in context: inout GraphicsContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 3),
            with: .color(color.opacity(opacity)),
            style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
        guard !label.isEmpty else { return }
        context.draw(
            Text(label).font(.system(size: 9, weight: .bold))
                .foregroundColor(color.opacity(opacity)),
            at: CGPoint(x: rect.minX + 2, y: rect.maxY + 2),
            anchor: .topLeading)
    }
}

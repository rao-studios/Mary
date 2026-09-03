//
//  MaryColumns.swift
//  Mary
//
//  WHAT: A row of columns that start at their floor and grow toward their
//        ideal, in priority order, before any leftover goes to whichever
//        column has no ceiling.
//  IN:   AbilityStudioView's shell (rail | main | drawer; recipe | tune+skills).
//  OUT:  Children must carry `.maryColumn(_:)` — see PIN.
//  PIN:  Not `HStack`: it offers each child `remaining / childrenLeft` in
//        order, so a `maxWidth: .infinity` main column sized last starves
//        beside flexible rail/drawer spans. This starts everyone at their
//        minimum first, which is also what makes the reported minimum
//        honest for `.contentMinSize`.
//  PIN:  It reads each child's span from `MaryColumnSpan`, never by measuring
//        it. Probing for min/ideal/max instead cost ~200 ms per resize frame:
//        six `sizeThatFits` calls per child per pass, one of them proposing a
//        million points, each forcing a real layout of a whole pane.
//

import SwiftUI

struct MaryColumns: Layout {
    var spacing: CGFloat = 0

    /// One child's width range, and whether it may take the leftover.
    private struct Column {
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
        let priority: Double
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let columns = columns(subviews)
        let totalSpacing = spacing * CGFloat(subviews.count - 1)
        let height = proposal.height ?? tallestSubview(subviews, proposal: proposal)

        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            return CGSize(width: columns.reduce(0) { $0 + $1.ideal } + totalSpacing, height: height)
        }
        let totalMin = columns.reduce(0) { $0 + $1.min } + totalSpacing
        return CGSize(width: Swift.max(proposedWidth, totalMin), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let widths = widths(for: bounds.width, subviews: subviews)
        var x = bounds.minX
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: widths[index], height: bounds.height))
            x += widths[index] + spacing
        }
    }

    // MARK: - Sizing

    /// Every column starts at its floor; what is left over grows them toward
    /// their ideal in descending `.layoutPriority`, and any remainder after
    /// that goes to the columns with no ceiling.
    private func widths(for available: CGFloat, subviews: Subviews) -> [CGFloat] {
        let columns = columns(subviews)
        let totalSpacing = spacing * CGFloat(subviews.count - 1)
        var widths = columns.map(\.min)
        var remaining = Swift.max(0, available - totalSpacing) - widths.reduce(0, +)
        let byPriority = columns.indices.sorted { columns[$0].priority > columns[$1].priority }

        for index in byPriority where remaining > 0 {
            let room = Swift.max(0, Swift.min(columns[index].ideal, columns[index].max) - widths[index])
            let grant = Swift.min(room, remaining)
            widths[index] += grant
            remaining -= grant
        }

        if remaining > 0 {
            let growable = byPriority.filter { columns[$0].max - widths[$0] > 0.5 }
            if !growable.isEmpty {
                let share = remaining / CGFloat(growable.count)
                for index in growable {
                    let grant = Swift.min(Swift.max(0, columns[index].max - widths[index]), share)
                    widths[index] += grant
                    remaining -= grant
                }
                // Whatever the capped ones could not take goes to the first
                // column that still has room, so no width is left unplaced.
                if remaining > 0, let first = growable.first(where: { columns[$0].max.isInfinite }) {
                    widths[first] += remaining
                }
            }
        }
        return widths
    }

    /// A child that declares a span is taken at its word. One that does not
    /// is measured — the fallback exists so this layout still behaves for an
    /// undeclared child, not because any caller relies on it.
    private func columns(_ subviews: Subviews) -> [Column] {
        subviews.map { subview in
            if let span = subview[MaryColumnSpan.self] {
                return Column(min: span.min, ideal: span.ideal, max: span.max, priority: subview.priority)
            }
            let measured = subview.sizeThatFits(.unspecified).width
            return Column(min: 0, ideal: measured, max: .infinity, priority: subview.priority)
        }
    }

    private func tallestSubview(_ subviews: Subviews, proposal: ProposedViewSize) -> CGFloat {
        subviews.reduce(0) { tallest, subview in
            Swift.max(tallest, subview.sizeThatFits(proposal).height)
        }
    }
}

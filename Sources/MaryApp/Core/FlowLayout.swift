//
//  FlowLayout.swift
//  Mary
//
//  Intrinsic-width flow layout: each subview is measured with `.unspecified`
//  and keeps the width its own content asks for, wrapping to a new line when
//  the row runs out. Originally a word-level layout for the contribution
//  highlight text (each word its own subview, so per-word frames could back
//  the brushstroke overlay); verbatim port from Sis.
//
//  IT LIVES IN Core NOW BECAUSE IT IS THE ANSWER TO A RECURRING BUG, not a
//  highlight detail. `LazyVGrid(GridItem(.adaptive(minimum:)))` gives every
//  cell the COLUMN's width, so a grid sized for icon chips (28 pt) hands that
//  width to a text chip and the label breaks mid-word — "compose" rendered as
//  "com / pos / e". A column is the wrong authority for a label's width; the
//  label's own content is. Anything laying out variable-width text chips
//  should use this and `MaryChip`, never an adaptive grid.
//

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        var maxWidth: CGFloat = 0

        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            height += rowHeight
            if i > 0 { height += lineSpacing }
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.size.width }
            maxWidth = max(maxWidth, rowWidth)
        }

        return CGSize(width: proposal.width ?? maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY

        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            if i > 0 { y += self.lineSpacing }
            var x = bounds.minX
            for item in row {
                item.subview.place(
                    at: CGPoint(x: x, y: y + (rowHeight - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += rowHeight
        }
    }

    private func computeRows(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> [[(subview: LayoutSubviews.Element, size: CGSize)]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[(subview: LayoutSubviews.Element, size: CGSize)]] = [[]]
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append((subview, size))
            currentWidth += size.width + spacing
        }
        return rows
    }
}

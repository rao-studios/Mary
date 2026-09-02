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
//

import SwiftUI

struct MaryColumns: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let totalSpacing = spacing * CGFloat(subviews.count - 1)
        let height = subviews
            .map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: proposal.height)).height }
            .max() ?? 0

        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            let ideals = subviews.map { idealWidth($0, height: proposal.height) }
            return CGSize(width: ideals.reduce(0, +) + totalSpacing, height: height)
        }
        let mins = subviews.map { minWidth($0, height: proposal.height) }
        let totalMin = mins.reduce(0, +) + totalSpacing
        return CGSize(width: max(proposedWidth, totalMin), height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let n = subviews.count
        let totalSpacing = spacing * CGFloat(n - 1)
        let available = max(0, bounds.width - totalSpacing)

        let mins = subviews.map { minWidth($0, height: bounds.height) }
        let ideals = subviews.map { idealWidth($0, height: bounds.height) }
        let maxes = subviews.map { maxWidth($0, height: bounds.height) }

        var widths = mins
        var remaining = available - mins.reduce(0, +)
        let byPriorityDescending = (0..<n).sorted { subviews[$0].priority > subviews[$1].priority }

        if remaining > 0 {
            for i in byPriorityDescending {
                guard remaining > 0 else { break }
                let room = max(0, min(ideals[i], maxes[i]) - widths[i])
                let grant = min(room, remaining)
                widths[i] += grant
                remaining -= grant
            }
        }

        if remaining > 0 {
            let flexible = byPriorityDescending.filter { maxes[$0] - widths[$0] > 0.5 }
            if !flexible.isEmpty {
                let share = remaining / CGFloat(flexible.count)
                for i in flexible {
                    let room = max(0, maxes[i] - widths[i])
                    let grant = min(room, share)
                    widths[i] += grant
                    remaining -= grant
                }
                if remaining > 0, let top = flexible.first {
                    widths[top] += remaining
                    remaining = 0
                }
            }
        }

        var x = bounds.minX
        for i in 0..<n {
            subviews[i].place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: widths[i], height: bounds.height))
            x += widths[i] + spacing
        }
    }

    private func minWidth(_ subview: LayoutSubviews.Element, height: CGFloat?) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: 0, height: height)).width
    }

    private func idealWidth(_ subview: LayoutSubviews.Element, height: CGFloat?) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: nil, height: height)).width
    }

    /// A column with no declared ceiling still returns a finite number from
    /// `sizeThatFits`, so growth is detected by probing a very wide proposal:
    /// a bounded column echoes its `maxWidth`, an unbounded one keeps growing
    /// past the probe and is treated as `.infinity`.
    private func maxWidth(_ subview: LayoutSubviews.Element, height: CGFloat?) -> CGFloat {
        let probe: CGFloat = 1_000_000
        let width = subview.sizeThatFits(ProposedViewSize(width: probe, height: height)).width
        return width >= probe - 1 ? .infinity : width
    }
}

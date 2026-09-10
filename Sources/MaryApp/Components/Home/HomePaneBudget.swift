//
//  HomePaneBudget.swift
//  Mary
//
//  WHAT: How many of Home's open side panes fit at a given window width.
//  IN:   HomeSessionView, reading \.maryWindowSize.
//  OUT:  the visible subset of Home's openPanes — everything past the
//        budget folds away and returns once the window is wide enough again.
//  PIN:  Pure arithmetic on the conversation's floor plus one side-pane floor
//        per slot, so the split's summed minimums can never exceed the
//        window — no feedback loop, no hysteresis needed.
//

import SwiftUI

enum HomePaneBudget {
    /// How many side panes fit beside the conversation at this width.
    static func count(width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let forPanes = width - Paper.Layout.conversation.min - Paper.Layout.splitAllowance
        guard forPanes > 0 else { return 0 }
        return max(0, Int(forPanes / Paper.Layout.sidePane.min))
    }

    /// The most-recently-wanted panes, up to the budget. `open` is oldest
    /// first, so widening the window restores exactly what was folded, in
    /// the order it was asked for.
    static func visible(open: [Home.Pane], width: CGFloat) -> Set<Home.Pane> {
        Set(open.suffix(count(width: width)))
    }
}

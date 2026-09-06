//
//  PageListDerivation.swift
//  MaryComputerUse
//
//  WHAT: A run of rows laid out alike, down the page's own column, is a list.
//  IN:   the merged rows and their regions, at the seal
//  OUT:  a `list` group, and so `RowFacts.inResultGroup`
//  PIN:  THE ACCESSIBILITY LANE MADE NAMING BETTER AND GROUPING WORSE. A walked
//        row that lands on no seen row is added with no group at all — the tree
//        publishes roles and names, never the visual grouping — and
//        `inResultGroup` is read off the group. So the round that gave a results
//        page real titles also stopped four legs finding a result at all: "no row
//        in this reading answers the class". The names got better and the class
//        got unanswerable.
//        WHAT A PERSON SEES IS THE SHAPE. Nobody reads a results page by markup;
//        they see the same shape repeated down the middle of the page and count
//        it. That is geometry, it is available here, and it is the one thing
//        neither lane publishes on its own.
//        IT ONLY EVER ADDS. A row the reading already grouped keeps its group —
//        the pixel lane's grouping is a real reading of the page and this is a
//        fallback for what it did not reach, never a second opinion about what
//        it did.
//

import CoreGraphics
import Foundation

public enum PageListDerivation {

    /// How many rows of a shape before it is a list rather than a coincidence.
    /// Three is the smallest run that has a rhythm to it; two is a pair.
    public static let minimumRun = 3
    /// How far apart two rows' left edges may sit and still be the same column,
    /// in points. A results page indents its titles identically; a paragraph
    /// that happens to start nearby does not repeat.
    public static let edgeTolerance: CGFloat = 24
    /// How much two rows' widths may differ, as a share of the wider one. Titles
    /// in a list are set to one measure and wrap; they are not all one length.
    public static let widthTolerance = 0.5
    /// A gap wider than this many times the row's own height is a different part
    /// of the page, not the next item.
    public static let gapFactor: CGFloat = 6

    /// The groups the reading did not find, from the shape of what is left.
    ///
    /// Returns the rows with their new group references and the groups to add.
    public static func lists(
        rows: [PageRow], groups: [PageGroup]
    ) -> (rows: [PageRow], groups: [PageGroup]) {
        // ONLY THE PAGE'S OWN COLUMN, and only rows nothing else claimed. A
        // site's navigation is a run of alike rows too — it sits in `leading` or
        // `header`, which is exactly what those regions are for.
        let loose = rows.indices.filter {
            rows[$0].group == nil
                && rows[$0].region == .main
                && rows[$0].affordance == .press
                && !rows[$0].label.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard loose.count >= minimumRun else { return (rows, groups) }

        let ordered = loose.sorted { rows[$0].frame.minY < rows[$1].frame.minY }
        var runs: [[Int]] = []
        var run: [Int] = []
        for index in ordered {
            guard let last = run.last else {
                run = [index]
                continue
            }
            if alike(rows[last], rows[index]) {
                run.append(index)
            } else {
                if run.count >= minimumRun { runs.append(run) }
                run = [index]
            }
        }
        if run.count >= minimumRun { runs.append(run) }
        guard !runs.isEmpty else { return (rows, groups) }

        var rows = rows
        var groups = groups
        var nextID = (groups.map(\.id).max() ?? 0) + 1
        for run in runs {
            let group = PageGroup(
                id: nextID, kind: .list, title: nil,
                memberOrdinals: run.map { rows[$0].ordinal }.sorted())
            let reference = PageGroupRef(id: nextID, kind: .list, title: nil)
            for index in run { rows[index].group = reference }
            groups.append(group)
            nextID += 1
        }
        return (rows, groups)
    }

    /// Two rows laid out as items of one list: same left edge, comparable width,
    /// and near enough vertically to be the next one down.
    static func alike(_ a: PageRow, _ b: PageRow) -> Bool {
        guard abs(a.frame.minX - b.frame.minX) <= edgeTolerance else { return false }
        let wider = max(a.frame.width, b.frame.width)
        guard wider > 0,
              Double(abs(a.frame.width - b.frame.width) / wider) <= widthTolerance
        else { return false }
        let gap = b.frame.minY - a.frame.maxY
        guard gap >= 0 else { return false }
        return gap <= max(a.frame.height, b.frame.height) * gapFactor
    }
}

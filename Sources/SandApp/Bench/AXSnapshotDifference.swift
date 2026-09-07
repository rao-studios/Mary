//
//  AXSnapshotDifference.swift
//  Sand
//
//  WHAT: What actually changed on the target between two reads.
//  IN:   the wireframe poller's snapshots, either side of a dispatch
//  OUT:  the Effect card
//  PIN:  THE MISSING HALF OF THE BENCH. Sand could say what a skill RETURNED —
//        a summary and a receipt, both written by the thing being tested — and
//        nothing about what the application did. A recipe that reports success
//        on the mere absence of a refusal (every `.mary` macUI recipe does)
//        looks identical to one that worked. Two reads and a diff is the same
//        "prove it by looking again" rule the browser and media lanes already
//        live by, applied to the bench rather than to a lane.
//        LABEL FLIPS ARE THE POINT. "Pause" becoming "Play" on the same node is
//        the clearest evidence a transport moved that a machine can produce.
//        PURE, AND SAND-ONLY. It is a function of two values, with no notion of
//        what was dispatched — it earns a place lower in the stack only if
//        something other than a bench ever needs it.
//

import Foundation
import MaryComputerUse

struct AXSnapshotDifference {

    struct LabelChange: Identifiable {
        let id: AXNodeID
        let role: String
        let before: String
        let after: String
    }

    var windowTitleBefore: String?
    var windowTitleAfter: String?
    var focusBefore: String?
    var focusAfter: String?
    var labelChanges: [LabelChange]
    var added: Int
    var removed: Int
    /// Nothing read differently. A real answer, and the one worth shouting
    /// about when a skill claims it acted.
    var isEmpty: Bool {
        windowTitleBefore == windowTitleAfter
            && focusBefore == focusAfter
            && labelChanges.isEmpty && added == 0 && removed == 0
    }

    /// How many label flips are worth naming before the list stops being read.
    static let namedLimit = 6

    static func between(
        _ before: AXAppSnapshot?, _ after: AXAppSnapshot?
    ) -> AXSnapshotDifference? {
        guard let before, let after else { return nil }
        let beforeNodes = index(before)
        let afterNodes = index(after)

        var changes: [LabelChange] = []
        for (id, node) in beforeNodes {
            guard let now = afterNodes[id] else { continue }
            let was = node.label ?? ""
            let is_ = now.label ?? ""
            guard was != is_, !(was.isEmpty && is_.isEmpty) else { continue }
            changes.append(LabelChange(id: id, role: now.role, before: was, after: is_))
        }
        // Stable, and the interactive ones first: a button whose word changed is
        // a receipt, a static text that re-rendered is usually noise.
        changes.sort {
            $0.role == $1.role ? $0.before < $1.before : $0.role < $1.role
        }

        return AXSnapshotDifference(
            windowTitleBefore: before.windows.first?.title,
            windowTitleAfter: after.windows.first?.title,
            focusBefore: focusedLabel(beforeNodes),
            focusAfter: focusedLabel(afterNodes),
            labelChanges: Array(changes.prefix(namedLimit)),
            added: afterNodes.keys.filter { beforeNodes[$0] == nil }.count,
            removed: beforeNodes.keys.filter { afterNodes[$0] == nil }.count)
    }

    private static func index(_ snapshot: AXAppSnapshot) -> [AXNodeID: AXNodeSnapshot] {
        var nodes: [AXNodeID: AXNodeSnapshot] = [:]
        func walk(_ node: AXNodeSnapshot) {
            nodes[node.id] = node
            for child in node.children { walk(child) }
        }
        for window in snapshot.windows {
            guard let root = window.root else { continue }
            walk(root)
        }
        return nodes
    }

    private static func focusedLabel(_ nodes: [AXNodeID: AXNodeSnapshot]) -> String? {
        nodes.values.first { $0.isFocused }.map { node in
            node.label.map { "\(node.role) \"\($0)\"" } ?? node.role
        }
    }
}

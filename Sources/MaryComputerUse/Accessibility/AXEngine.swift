//
//  AXEngine.swift
//  MaryComputerUse
//
//  WHAT: Accessibility facade — one-shot snapshot and detail. TIER 0.
//  OUT:  AXSnapshotBuilder / AXDetailReader / AXTreeWalker
//        Web/: WebContentHost → WebAreaLocator
//  PIN:  Mary polls; there is no streamer and no wake lane in this build, so a
//        lazily-built web tree may simply not be there yet — that is an honest
//        miss, never a retry loop. No pixels: Sight/ScreenRegionCapture is a
//        tier above this one. Accessibility/ imports nothing from Sight/,
//        Hands/, Stage/ or Process/.
//

import ApplicationServices

public enum AXEngine {

    /// One-shot snapshot of a process's windows. Budgets: AXSnapshotBuilder.
    /// `.exhaustive` = extraction once, not the stream's watchable cadence.
    public static func snapshot(
        pid: pid_t, options: AXSnapshotBuilder.Options = .init()
    ) -> AXAppSnapshot? {
        AXSnapshotBuilder.snapshot(pid: pid, options: options)
    }

    /// One-shot detail: walk once, caller picks a node, AXDetailReader decorates.
    /// PIN: select from this snapshot — an id from an earlier walk goes stale.
    public static func detail(
        pid: pid_t,
        options: AXSnapshotBuilder.Options = .exhaustive,
        budget: AXDetailReader.Budget = .probe,
        select: (AXAppSnapshot) -> AXNodeID?
    ) -> (snapshot: AXAppSnapshot, detail: AXSubtreeDetail)? {
        guard let result = AXSnapshotBuilder.build(pid: pid, options: options),
              let nodeID = select(result.snapshot),
              let subtree = result.snapshot.subtree(withID: nodeID),
              let detail = AXDetailReader.read(
                subtree: subtree, table: result.elements, budget: budget)
        else { return nil }
        return (result.snapshot, detail)
    }

    /// Detail for an id obtained elsewhere. Fresh walk; nil if the id died.
    /// Prefer the selecting form when the choice can be made on this walk.
    public static func detail(
        pid: pid_t,
        nodeID: AXNodeID,
        options: AXSnapshotBuilder.Options = .exhaustive,
        budget: AXDetailReader.Budget = .probe
    ) -> (snapshot: AXAppSnapshot, detail: AXSubtreeDetail)? {
        detail(pid: pid, options: options, budget: budget, select: { _ in nodeID })
    }
}

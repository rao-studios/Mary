//
//  AXEngine.swift
//  MaryPlugin
//
//  WHAT: Accessibility facade — one-shot snapshot and detail.
//  OUT:  AXSnapshotBuilder / AXDetailReader / AXTreeWalker
//        Web/: WebContentHost → WebAXWakeup → WebAreaLocator
//              → BrowserAXReadiness, AXSnapshotBuilder, AXSnapshotStreamer
//        Scripting/: ScriptedGap → ScriptabilityProbe → CollectionPlanner
//              → GenericReadScript → ScriptedGraft
//  PIN:  Mary polls; no live streamer. No pixels (ScreenRegionCapture stays out).
//        One-shot snapshot does not wake a lazy web tree — call
//        BrowserAXReadiness.ensureWebContentAX first if the page matters.
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

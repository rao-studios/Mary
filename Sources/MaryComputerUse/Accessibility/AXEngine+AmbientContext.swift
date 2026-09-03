//
//  AXEngine+AmbientContext.swift
//  MaryComputerUse
//
//  WHAT: Ambient poll door — one walk, one derived AXAmbientContext.
//  IN:   AXSnapshotBuilder.build (poll cadence, never .exhaustive)
//  OUT:  AXAmbientContext
//  PIN:  Does not wake a lazy web tree.

import ApplicationServices

extension AXEngine {

    /// One-shot ambient context: walk once, derive once. Uses `AXSnapshotBuilder.build`
    /// rather than two separate calls so the roster, the focused element, the web tallies
    /// and the gap records all describe the SAME walk.
    public static func ambientContext(
        pid: pid_t,
        options: AXSnapshotBuilder.Options = .init(),
        scope: AXElementRoster.Scope = AXAmbientContext.ambientScope,
        declaredEditorRoles: Set<String> = []
    ) -> AXAmbientContext? {
        guard let built = AXSnapshotBuilder.build(pid: pid, options: options)
        else { return nil }
        return AXAmbientContext(
            snapshot: built.snapshot,
            scope: scope,
            limit: AXElementRoster.publishedLimit,
            declaredEditorRoles: declaredEditorRoles,
            // Hosts web content? Unwoken Chromium/Electron: native chrome only.
            webContentHost: WebContentHost.classify(
                pid: pid, bundleID: built.snapshot.bundleID) != .none,
            observersCovered: nil,
            observersTotal: nil)
    }
}

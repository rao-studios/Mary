//
//  AXEngine+AmbientContext.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  THE AMBIENT PROVIDER: one walk, one derived artifact. This is the door
//  the ambient observer knocks on every poll, so it deliberately rides the
//  STREAM-cadence budgets (`Options()`, 1500-node front window), never
//  `.exhaustive` — an ambient glance is a diet, not an extraction.
//

import ApplicationServices

extension AXEngine {

    /// One-shot ambient context: walk once, derive once. Uses
    /// `AXSnapshotBuilder.build` rather than two separate calls so the
    /// roster, the focused element, the web tallies and the gap records all
    /// describe the SAME walk — the "one walk, not two" rule `detail`'s
    /// header earned on Chrome.
    ///
    /// Nil only when AX is untrusted or the process is gone (the builder's
    /// own contract). Like `snapshot(pid:)`, this does not wake a lazy web
    /// tree — an unwoken Chromium target honestly reports its chrome, and
    /// `web.readiness` stays nil ("not yet read", never "empty page").
    public static func ambientContext(
        pid: pid_t,
        options: AXSnapshotBuilder.Options = .init(),
        scope: AXElementRoster.Scope = AXAmbientContext.ambientScope
    ) -> AXAmbientContext? {
        guard let built = AXSnapshotBuilder.build(pid: pid, options: options)
        else { return nil }
        return AXAmbientContext(
            snapshot: built.snapshot,
            scope: scope,
            limit: AXElementRoster.publishedLimit,
            // THE ONE THING THE DEFERRED WEB LANE STILL OWES: whether this
            // process hosts web content at all. Chromium and Electron build
            // NO web-content accessibility hierarchy until an assistive
            // client announces itself, so a plain walk of VS Code or Slack
            // finds the native shell and nothing inside it. Measured in
            // Bonnie: one element published where 176 existed. Without the
            // wake lane Mary cannot fix that — but she can refuse to claim
            // she saw a page, and this flag is how the surface says so.
            webContentHost: WebContentHost.classify(
                pid: pid, bundleID: built.snapshot.bundleID) != .none,
            observersCovered: nil,
            observersTotal: nil)
    }
}

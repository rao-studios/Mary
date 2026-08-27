//
//  AXEngine.swift
//  MaryAdapter
//
//  THE AX ENGINE — Mary's consolidated accessibility-tree machinery:
//  bounded walking (`AXTreeWalker`), value-type snapshots fit for a live
//  wireframe (`AXNodeSnapshot`/`AXAppSnapshot`), a builder that walks a
//  process's windows into one (`AXSnapshotBuilder`), an observer hub that
//  turns AX notifications into invalidations (`AXObserverHub`), a refresh
//  policy that turns invalidations + timing into a walk/poll/sleep decision
//  (`AXRefreshPolicy`), and the streaming actor that ties them together
//  (`AXSnapshotStreamer`). This facade is the front door for both Clyde (the
//  live wireframe app, `Sources/ClydeApp/`) and BonnieApp's probes.
//
//  THE WEB SUB-ENGINE (`Web/`, 2026-08-25) is the first of two
//  specializations inside this directory, because web content is one of the
//  two things an AX walk cannot simply find: Chromium — and therefore every Electron and CEF app —
//  builds NO web-content hierarchy until an assistive client asks, and a
//  page that has not been built is indistinguishable from an app with no
//  content. `Web/WebContentHost` classifies what kind of host a pid is on
//  mechanical evidence, `Web/WebAXWakeup` asks the lazy ones to wake and
//  polls for an honest verdict, `Web/WebAreaLocator` finds the page roots,
//  and the builder walks what it finds on its own budget (a page is an
//  order of magnitude bigger than the native chrome around it). Three
//  files consume it: `BrowserAXReadiness` (the stable public facade over
//  the wake), `AXSnapshotBuilder` (the second lane), `AXSnapshotStreamer`
//  (walk now, fold the page in when it wakes). See `docs/DECOMPOSITION.md`
//  §IV.8.
//
//  THE SCRIPTING SUB-ENGINE (`Scripting/`, 2026-08-26) is the second, for
//  the opposite failure. Web content is AX that has not been ASKED FOR;
//  scripted gaps are AX that was never IMPLEMENTED. Keynote's slide
//  navigator is a scroll area whose only child is its own scrollbar while
//  `AXContentSize` declares content 2.25× its viewport — there is no wake
//  signal to send, because the app simply never built that tree. The lane
//  is four steps, and NO STEP KNOWS THE NAME OF ANY APP:
//  `Scripting/ScriptedGap` detects the gap as mechanical evidence;
//  `Scripting/ScriptabilityProbe` asks whether the app vends a dictionary at
//  all; `Scripting/CollectionPlanner` DERIVES from that dictionary's own
//  containment and types which collection could be behind the gap, how to
//  label an item, and where the current one is; `Scripting/GenericReadScript`
//  writes a bounded read-only AppleScript from those derived terms; and
//  `Scripting/ScriptedGraft` puts the answer back into the published
//  snapshot as clearly-marked `.scripted` nodes. `ScriptedFillPolicy` is the
//  diff that decides when the walked truth has changed enough to re-ask.
//  See `docs/DECOMPOSITION.md` §IV.9.
//
//  WHAT CONSOLIDATED (2026-08-25), CONSERVATIVELY:
//    - `SafariWebSurface.walk` and `ProbeShaderFeel`'s verbatim duplicate now
//      forward to `AXTreeWalker.walk` — same budgets, same call sites,
//      behavior unchanged.
//    - `AccessibilityWindowCore` (window enumerate/raise/restore/full-screen)
//      moved here from `Adapters/WindowManagement/` — same target, same
//      name, its two call sites untouched.
//    - `BrowserAXReadiness` (Chromium AX tree wake-up) moved here from
//      `Shared/` — whole file, zero edits.
//
//  WHAT DELIBERATELY DID NOT MOVE OR CHANGE — three other walkers stay
//  independent this pass, each specialized enough that folding it into the
//  generic core would be a behavior change disguised as a refactor:
//    - `AXSelectionReader.descendToText` (MaryAmbient) and
//      `PagesAX.descendToText`/`PagesAX+ElementResolution`'s variant (both
//      `Adapters/Pages/`) — bounded descents tuned for "find the positive
//      selection", not general tree collection.
//    - `RemoteHandsStateProvider`'s `kAXChildrenAttribute` descent — surface/
//      anchor/discriminator observation with its own evidence policy.
//    - `PageElementReader`/`PageElementModels`/`PageElementActions` — a
//      page-semantic CONSUMER of the walker (reading order, dedup doctrine,
//      17-role collection), not tree-walking machinery itself; it already
//      benefits from the AXTreeWalker consolidation through the shim.
//  `ScreenRegionCapture` stays out too — it is pixels-via-AX-hint, and this
//  engine's whole premise (and Clyde's) is no pixels.
//
//  See `docs/DECOMPOSITION.md` for the dated write-up and verification
//  recipe.
//

import ApplicationServices

public enum AXEngine {

    /// One-shot best-effort snapshot of a process's windows. See
    /// `AXSnapshotBuilder` for budgets and the IPC-diet rationale;
    /// `Options.exhaustive` is the preset for extraction ("everything this
    /// app exposes, once") as opposed to the stream's watchable cadence.
    ///
    /// NOTE for a browser or Electron target: this does not wake a lazy web
    /// tree — a one-shot walk has nowhere to put the six-second wait. Call
    /// `BrowserAXReadiness.ensureWebContentAX` first if the page matters.
    public static func snapshot(
        pid: pid_t, options: AXSnapshotBuilder.Options = .init()
    ) -> AXAppSnapshot? {
        AXSnapshotBuilder.snapshot(pid: pid, options: options)
    }

    /// A live, invalidation-driven stream of snapshots for one process. The
    /// caller owns the returned streamer's lifetime and must `stop()` it.
    /// `pacer` drives the tracking pump's cadence during a drag/resize —
    /// defaults to a headless `ClockFramePacer`; Clyde installs a
    /// `DisplayLinkFramePacer` for vsync-aligned tracking.
    // NO STREAM. Bonnie's engine had a second lane: an invalidation-driven
    // streamer that kept a live tree warm and published diffs, which is what
    // a realtime wireframe viewer needs. Mary polls — one walk when the
    // surface tier asks — and the streamer family returns with the thing that
    // needs it. Every consumer here reads a snapshot.

    /// One-shot detail read: walk once, let the caller pick a node out of
    /// THAT walk, then decorate its subtree with what the streamed diet
    /// refuses (see `AXDetailReader`). The extraction counterpart to
    /// `AXSnapshotStreamer.detail(for:)` — for probes and anything else with
    /// no live stream to ask.
    ///
    /// ONE WALK, NOT TWO. Selecting from the same snapshot the element table
    /// came from is what makes this reliable against a moving target: an id
    /// carried over from an earlier, separate walk goes stale exactly where
    /// detail is most interesting — measured live on Chrome, whose page
    /// nodes are destroyed and recreated between two walks seconds apart, so
    /// every such lookup refused. `select` returns nil to mean "nothing here
    /// matches", which answers nil overall.
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

    /// The same read for an id obtained ELSEWHERE — from an earlier
    /// snapshot, a roster row, a saved reference. Costs a fresh walk, and
    /// answers nil when the id did not survive it: `CFHash` is stable only
    /// while the element lives, and one that recycled is caught by the
    /// role recheck. Prefer the selecting form above where the choice can be
    /// made against a fresh walk instead.
    public static func detail(
        pid: pid_t,
        nodeID: AXNodeID,
        options: AXSnapshotBuilder.Options = .exhaustive,
        budget: AXDetailReader.Budget = .probe
    ) -> (snapshot: AXAppSnapshot, detail: AXSubtreeDetail)? {
        detail(pid: pid, options: options, budget: budget, select: { _ in nodeID })
    }
}

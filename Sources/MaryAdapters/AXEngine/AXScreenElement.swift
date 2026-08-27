//
//  AXScreenElement.swift
//  MaryAdapter
//
//  THE AX ENGINE — see AXEngine.swift for the directory's doctrine header.
//
//  ONE PUBLISHED THING, FROM A SNAPSHOT RATHER THAN A LIVE PAGE. This is the
//  snapshot lane's answer to `PageElement` — same job (something a person can
//  point at by name, in reading order, with enough state to resolve a
//  phrase against), but built from a value-type `AXAppSnapshot` instead of a
//  live web area, and therefore without a live `AXUIElement`, a URL, or a
//  numeric range. `AXElementRoster` is what produces these; this file only
//  says what one of them is.
//
//  NO LIVE HANDLE, ON PURPOSE. Every existing AX-facing type in this
//  directory (`AXNodeSnapshot`, `AXAppSnapshot`) is a plain Sendable value
//  for the same reason `AXNodeSnapshot`'s own header gives: a wireframe
//  compares, hashes, and hands snapshots across actor boundaries without
//  touching AX again. An element resolved against one of these snapshots
//  inherits that property — it can be resolved on a background actor, kept
//  around, compared, all without a live process handle. `id` is how it
//  re-attaches to AX later: `AXHitTest.frame(of:in:)` re-resolves a current
//  frame from a fresher snapshot, and `AXSnapshotBuilder`'s internal element
//  table (never published) is how a future actuation engine turns an id back
//  into an `AXUIElement` — that seam is deliberately not opened here.
//
//  `isBackedByLiveAX` EXISTS BECAUSE OF THE SCRIPTING SUB-ENGINE. A
//  `.scripted` node (`AXEngine/Scripting/ScriptedGraft`) was never walked
//  from AX — it is a synthesized row with a deterministic id that no
//  `AXUIElement` has ever backed, published because it is real content a
//  person can hear about, not because it can be pressed. A resolver or an
//  actuator built on top of this type must be able to ask the difference.
//

import CoreGraphics
import Foundation

/// One resolvable thing on a snapshot, in the shape `AXElementRoster`
/// publishes it.
public struct AXScreenElement: Sendable, Equatable, Identifiable {
    /// 1-based position in reading order over the published list — the
    /// snapshot lane's answer to "the third video".
    public var ordinal: Int
    /// `AXNodeSnapshot.id` for a live-walked node, or a synthetic id for a
    /// `.scripted` graft. See `isBackedByLiveAX`.
    public var id: AXNodeID
    /// Which process this came from — the cross-app answerability the
    /// snapshot lane needs, since a roster is scoped to one `AXAppSnapshot`
    /// and the caller may be holding several.
    public var pid: pid_t
    public var appName: String
    public var windowID: AXNodeID
    public var windowTitle: String
    /// The raw AX role, e.g. `AXButton`, or `"BonnieScripted"` for a graft.
    public var role: String
    public var subrole: String?
    public var category: AXNodeCategory
    /// Never empty — `AXElementRoster` drops unlabeled nodes rather than
    /// publish an ordinal or a refusal rival with nothing to say.
    public var label: String
    /// Global, top-left-origin AX screen coordinates, already clipped to the
    /// window it came from — the snapshot-lane analogue of the page lane's
    /// viewport clip.
    public var frame: CGRect
    public var isEnabled: Bool
    public var isFocused: Bool
    /// Labeled container/scrollArea/webArea ancestors, oldest first,
    /// innermost last, capped at 4 — the cheap "in the sidebar" breadcrumb,
    /// recorded during the walk because it cannot be recovered after.
    public var containerTrail: [String]

    public init(
        ordinal: Int,
        id: AXNodeID,
        pid: pid_t,
        appName: String,
        windowID: AXNodeID,
        windowTitle: String,
        role: String,
        subrole: String? = nil,
        category: AXNodeCategory,
        label: String,
        frame: CGRect,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        containerTrail: [String] = []
    ) {
        self.ordinal = ordinal
        self.id = id
        self.pid = pid
        self.appName = appName
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.category = category
        self.label = label
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.containerTrail = containerTrail
    }

    /// False only for a `.scripted` graft. Everything else this type
    /// publishes was walked from a live `AXUIElement` at capture time — the
    /// handle just was not carried forward, per this file's header.
    public var isBackedByLiveAX: Bool {
        category != .scripted
    }
}

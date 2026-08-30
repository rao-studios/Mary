//
//  AXScreenElement.swift
//  MaryAdapter
//
//  WHAT: One published thing from a snapshot (PageElement's snapshot twin).
//  IN:   AXElementRoster  OUT: SpokenReference / AmbientSurfaceBridge
//  PIN:  No live handle. isBackedByLiveAX is false for ScriptedGraft rows.

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
    /// The raw AX role, e.g. `AXButton`, or `"MaryScripted"` for a graft.
    public var role: String
    public var subrole: String?
    public var category: AXNodeCategory
    /// Never empty — unlabeled nodes drop unless they match a declared editor role.
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

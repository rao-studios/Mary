//
//  AXScreenElement.swift
//  MaryComputerUse
//
//  WHAT: One published thing from a snapshot (PageElement's snapshot twin).
//  IN:   AXElementRoster  OUT: SpokenReference / AmbientSurfaceBridge
//  PIN:  No live handle. isBackedByLiveAX is false for any row the walk did
//        not take from a live element.
//        WHERE A ROW CAME FROM IS RECORDED, NOT INFERRED. A row read out of pixels and
//        a row walked from Accessibility look identical here and are not the same
//        claim: one has a live element behind it that can be pressed by name, the other
//        has only a rectangle. `provenance` is what keeps them tellable apart.

import CoreGraphics
import Foundation

/// Where a roster row came from — what kind of evidence stands behind it.
public enum AXElementProvenance: String, Sendable, Equatable, CaseIterable, Codable {
    /// Walked from a live Accessibility tree.
    case accessibility
    /// Grafted by a scripting sub-engine; no AX node ever existed.
    case scripted
    /// SEEN IN PIXELS. The frame is measured and the role is a classifier's guess;
    /// there is no element to press, only a place to click.
    case seen
}

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
    /// What kind of evidence produced this row.
    public var provenance: AXElementProvenance

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
        containerTrail: [String] = [],
        provenance: AXElementProvenance = .accessibility
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
        self.provenance = provenance
    }

    /// Whether a live `AXUIElement` stood behind this row when it was made. The handle
    /// is not carried forward (see the header) — this says whether one could be found
    /// again by walking, which a seen row can never promise.
    public var isBackedByLiveAX: Bool {
        provenance == .accessibility && category != .scripted
    }
}

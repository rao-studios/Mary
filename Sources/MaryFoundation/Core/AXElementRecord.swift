//
//  AXElementRecord.swift
//  MaryFoundation
//
//  ONE ADDRESSABLE THING, WHAT AND WHERE IN ONE VALUE. `AXFrame` (same
//  file's neighbor) is pure geometry on purpose — this is the record that
//  attaches it to what it locates: an element's identity, its words, and
//  its place in the tree, alongside its frame. This is what Clyde's
//  inspector shows for a selected element and what `--probe-ambient-surface`
//  prints — the same value, so the two can never describe one element
//  differently.
//
//  `identity` IS THE RE-FINDING KEY, not the ordinal. A position re-flows
//  the moment a window re-lays out; `role.lowercased() + "|" +
//  normalized(label)` is what the affordance lane already uses to re-find a
//  control between two reads a second apart
//  (`AffordanceResolver.identity(of:)`, `AmbientBridge.identity(of:)`) — this
//  record carries the same spelling so a JSON dump and a live re-read can
//  never disagree about which control is which.
//
//  PLAIN SYNTHESIZED CODABLE — see `AXFrame.swift`'s header for why this
//  layer never uses the strict `.mary`-integrity decoder.
//

import Foundation

/// What and where, in one addressable record.
public struct AXElementRecord: Codable, Hashable, Sendable {
    /// `role.lowercased() + "|" + normalized(label)` — the re-finding key,
    /// never the ordinal.
    public var identity: String
    /// 1-based reading-order position among the elements this record was
    /// published alongside. A position, not an identity — see `identity`.
    public var ordinal: Int
    /// The raw AX role, e.g. `AXButton`, or `"MaryScripted"` for a
    /// scripting-lane graft.
    public var role: String
    public var subrole: String?
    public var label: String
    /// The humanized word a person would say — "button", "text field".
    public var kind: String
    /// Labeled ancestors, innermost last — "in the sidebar, under Recents".
    public var containerTrail: [String]
    public var isEnabled: Bool
    public var isFocused: Bool
    public var appName: String
    public var pid: Int32
    public var windowTitle: String
    public var frame: AXFrame

    public init(
        identity: String,
        ordinal: Int,
        role: String,
        subrole: String? = nil,
        label: String,
        kind: String,
        containerTrail: [String] = [],
        isEnabled: Bool = true,
        isFocused: Bool = false,
        appName: String,
        pid: Int32,
        windowTitle: String,
        frame: AXFrame
    ) {
        self.identity = identity
        self.ordinal = ordinal
        self.role = role
        self.subrole = subrole
        self.label = label
        self.kind = kind
        self.containerTrail = containerTrail
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.appName = appName
        self.pid = pid
        self.windowTitle = windowTitle
        self.frame = frame
    }
}

//
//  AXElementRecord.swift
//  MaryFoundation
//
//  WHAT: One addressable AX element — identity, words, tree place, AXFrame.
//  IN:   AX snapshot / probe → this record.
//  OUT:  inspector, `--probe-ambient-surface`, AmbientCapture, BehavioralAction.
//  PIN:  Re-find via `identity` (`role.lowercased() + "|" + normalized(label)`),
//        same spelling as AffordanceResolver / AmbientBridge. Synthesized Codable.
//

import Foundation

/// What and where, in one addressable record.
public struct AXElementRecord: Codable, Hashable, Sendable {
    /// Re-finding key: `role.lowercased() + "|" + normalized(label)`.
    public var identity: String
    /// 1-based reading order among siblings published with this record.
    public var ordinal: Int
    /// Raw AX role (`AXButton`) or `"MaryScripted"` for a scripting graft.
    public var role: String
    public var subrole: String?
    public var label: String
    /// Spoken kind — "button", "text field".
    public var kind: String
    /// Labeled ancestors, innermost last.
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

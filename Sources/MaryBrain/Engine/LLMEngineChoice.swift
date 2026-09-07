//
//  LLMEngineChoice.swift
//  MaryBrain
//
//  WHAT: Which backend answers Mary's turns.
//  PIN:  WHO now, not WHERE. Every lane rides Sewn; this says which backend
//        Sewn uses. Raw values ARE the wire — they must equal Sewn's
//        LLMProvider ("mistral" | "tinker" | "local"), and a stored "hosted"
//        from before the three-way split decodes to .mistral rather than
//        throwing (a thrown decode makes Granite re-seed every setting).
//

import Foundation

/// Which backend answers Mary's turns, through Sewn.
public enum LLMEngineChoice: String, Codable, CaseIterable, Sendable {
    /// Mistral's hosted API, through the local Sewn server.
    case mistral
    /// This machine, through Sewn's on-device MLX backend.
    case local
    /// Thinking Machines (Tinker), through the local Sewn server.
    case tinker

    /// The wire contract with Sewn, pinned by a test on both sides.
    public static let sewnRawValues = ["mistral", "local", "tinker"]

    public var displayName: String {
        switch self {
        case .mistral: return "Mistral (Hosted)"
        case .local:   return "On-device"
        case .tinker:  return "Thinking Machines (Hosted)"
        }
    }

    /// Nothing leaves this machine for generation on this lane.
    public var isOnDevice: Bool { self == .local }

    /// TOLERANT BY DESIGN. `"hosted"` is the pre-split value for what is now
    /// Mistral; an unknown string is a newer build's case. Either way the
    /// answer is a working default, because throwing here would discard the
    /// user's entire settings file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LLMEngineChoice(rawValue: raw) ?? .mistral
    }
}

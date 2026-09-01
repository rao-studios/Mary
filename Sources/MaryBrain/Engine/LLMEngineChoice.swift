//
//  LLMEngineChoice.swift
//  MaryBrain
//
//  WHAT: Which inference engine answers Mary's turns.
//  PIN:  WHERE (on-device vs hosted), never WHO (vendor).
//

import Foundation

/// Which inference engine answers Mary's turns.
public enum LLMEngineChoice: String, Codable, CaseIterable, Sendable {
    /// On-device, through MLX. Nothing leaves the machine.
    case local
    /// The local Seer server, which reaches the cloud on Mary's behalf.
    case hosted

    public var displayName: String {
        switch self {
        case .local:  return "On-device"
        case .hosted: return "Hosted (via Seer)"
        }
    }
}

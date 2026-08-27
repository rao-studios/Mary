//
//  SeerTransportChoice.swift
//  MaryBrain
//
//  Which route carries a Seer-mode turn's reply.
//

import Foundation

public enum SeerTransportChoice: String, Codable, CaseIterable, Sendable {
    /// SSE chat + per-chunk `/v1/speak` synthesis via the Speech backend.
    case classic
    /// WebSocket turn with interleaved text and server-synthesized audio:
    /// speech starts with the opening pass (~1s) while retrieval runs.
    case realtime

    public var displayName: String {
        switch self {
        case .classic:  return "Classic"
        case .realtime: return "Realtime"
        }
    }
}

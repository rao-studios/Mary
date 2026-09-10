//
//  SewnTransportChoice.swift
//  MaryBrain
//
//  WHAT: Which route carries a Sewn-mode turn's reply (classic vs realtime).
//  IN:   Settings / brain
//  OUT:  SewnChatClient or SewnRealtimeClient
//
import Foundation

public enum SewnTransportChoice: String, Codable, CaseIterable, Sendable {
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

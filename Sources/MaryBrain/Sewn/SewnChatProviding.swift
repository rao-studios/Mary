//
//  SewnChatProviding.swift
//  MaryBrain
//
//  WHAT: Brain's seam onto Sewn chat.
//  IN:   MaryBrain
//  OUT:  tests script this; app wires SewnChatClient
//  PIN:  Brain never learns tokens, SSE, or HTTP.
//
import Foundation

/// One spoken-history message on the wire ("user" | "assistant").
public struct SewnChatMessage: Sendable, Codable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Events one Sewn chat stream yields. Tokens are visible text (citation markers are stripped server-side); contribution rides a trailing metadata chunk
public enum SewnChatEvent: Sendable {
    case token(String)
    case contribution(SewnContribution)
    case autoMemory(Bool)
    /// The scope this request went out under — yielded FIRST, before the auth guard and the transport open, so a signed-out or failed attempt still traces as "asked
    case scoped(SewnRequestTrace)
    /// Realtime content staging marker ("opening" | "grounded").
    case phase(String)
    /// One chunk of server-synthesized reply audio (float32 LE mono PCM).
    case audio(pcm: Data, sampleRate: Double)
    /// The server's TTS lane died mid-turn; text continues, the client
    /// should voice the remainder locally.
    case ttsFailed

    /// Whether this event is reply CONTENT the lane forwards to the user
    public var forwardsContent: Bool {
        switch self {
        case .token, .audio:
            return true
        case .contribution, .autoMemory, .scoped, .phase, .ttsFailed:
            return false
        }
    }
}

public protocol SewnChatProviding: Sendable {
    /// True when a turn can run in sewn mode (signed in, server reachable).
    func isReady() async -> Bool
    /// Lowercased Sewn user id, once signed in.
    func ownerID() async -> String?
    func stream(
        messages: [SewnChatMessage],
        instructions: String?
    ) -> AsyncThrowingStream<SewnChatEvent, Error>
}

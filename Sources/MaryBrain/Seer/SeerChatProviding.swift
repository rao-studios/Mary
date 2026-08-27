//
//  SeerChatProviding.swift
//  MaryBrain
//
//  The brain's seam onto Seer chat. MaryBrain talks to this protocol only,
//  so tests script it and the app wires the real client; the brain never
//  learns about tokens, SSE, or HTTP.
//

import Foundation

/// One spoken-history message on the wire ("user" | "assistant").
public struct SeerChatMessage: Sendable, Codable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Events one Seer chat stream yields. Tokens are visible text (citation
/// markers are stripped server-side); contribution rides a trailing metadata
/// chunk; autoMemory reports the chunk flag as seen (last value wins).
/// The last three cases are realtime-route only — the classic SSE client
/// never emits them.
public enum SeerChatEvent: Sendable {
    case token(String)
    case contribution(SeerContribution)
    case autoMemory(Bool)
    /// The scope this request went out under — yielded FIRST, before the
    /// auth guard and the transport open, so a signed-out or failed attempt
    /// still traces as "asked, nothing back" (the same unfinished-turns
    /// rationale as `AmbientTraceLog`: the turns that never finish are the
    /// ones worth seeing). The one untraced path is a session with no owner
    /// id at all — the scope is unbuildable there. In-band on purpose: the
    /// join to `RetrievalTraceLedger` rides the stream itself, so no
    /// cross-actor "current exchange" static exists. Observation only — no
    /// consumer may steer on it.
    case scoped(SeerRequestTrace)
    /// Realtime content staging marker ("opening" | "grounded").
    case phase(String)
    /// One chunk of server-synthesized reply audio (float32 LE mono PCM).
    case audio(pcm: Data, sampleRate: Double)
    /// The server's TTS lane died mid-turn; text continues, the client
    /// should voice the remainder locally.
    case ttsFailed

    /// Whether this event is reply CONTENT the lane forwards to the user —
    /// the discriminator behind the realtime pre-stream fallback (rule 2 in
    /// `runRealtimeSeerLane`): a turn has failed "pre-stream" only while no
    /// content-bearing event has been yielded. Declared beside the cases so
    /// no future case can ship unclassified: bookkeeping (`.scoped`),
    /// staging markers (`.phase`), lane-health signals (`.ttsFailed`) and
    /// trailing metadata (`.contribution`, `.autoMemory`) must answer false,
    /// or every pre-stream failure looks mid-turn and the invisible classic
    /// rerun is disabled.
    public var forwardsContent: Bool {
        switch self {
        case .token, .audio:
            return true
        case .contribution, .autoMemory, .scoped, .phase, .ttsFailed:
            return false
        }
    }
}

public protocol SeerChatProviding: Sendable {
    /// True when a turn can run in seer mode (signed in, server reachable).
    func isReady() async -> Bool
    /// Lowercased Seer user id, once signed in.
    func ownerID() async -> String?
    func stream(
        messages: [SeerChatMessage],
        instructions: String?
    ) -> AsyncThrowingStream<SeerChatEvent, Error>
}

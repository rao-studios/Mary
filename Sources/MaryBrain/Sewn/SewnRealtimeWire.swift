//
//  SewnRealtimeWire.swift
//  MaryBrain
//
//  WHAT: Wire shapes for Sewn realtime (`GET /v1/realtime/chat`).
//  IN:   SewnRealtimeClient
//  OUT:  turn.start / token / audio / turn.end
//  PIN:  One turn per connection.
//
import Foundation

enum SewnRealtimeWire {

    // MARK: - Outbound

    struct TurnStart: Encodable {
        var type = "turn.start"
        var request: SewnWire.ChatRequest
        var tts: TTSOptions

        struct TTSOptions: Encodable {
            var voiceID: String

            enum CodingKeys: String, CodingKey {
                case voiceID = "voice_id"
            }
        }
    }

    // MARK: - Inbound

    /// One tolerant shape for every JSON text frame — `type` steers, the
    /// optional fields fill per frame kind. `chunk` is the SSE trailing-chunk
    /// JSON, decoded with the existing tolerant StreamChunk Codable.
    struct InboundFrame: Decodable {
        var type: String
        var phase: String?
        var text: String?
        var sampleRate: Double?
        var chunk: SewnWire.StreamChunk?
        var stage: String?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case type, phase, text, chunk, stage, message
            case sampleRate = "sample_rate"
        }
    }
}

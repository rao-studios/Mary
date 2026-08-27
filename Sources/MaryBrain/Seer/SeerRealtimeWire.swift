//
//  SeerRealtimeWire.swift
//  MaryBrain
//
//  Wire shapes for Seer's realtime WebSocket route (`GET /v1/realtime/chat`).
//  One turn per connection. Outbound: a single `turn.start` embedding the
//  exact ChatRequest the SSE route accepts. Inbound: JSON text frames
//  (token/phase/audio.begin/tts.failed/metadata/turn.end/error) plus raw
//  binary frames of float32 LE mono PCM; `audio.begin` announces the format
//  once and socket order implies audio sequence.
//

import Foundation

enum SeerRealtimeWire {

    // MARK: - Outbound

    struct TurnStart: Encodable {
        var type = "turn.start"
        var request: SeerWire.ChatRequest
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
        var chunk: SeerWire.StreamChunk?
        var stage: String?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case type, phase, text, chunk, stage, message
            case sampleRate = "sample_rate"
        }
    }
}

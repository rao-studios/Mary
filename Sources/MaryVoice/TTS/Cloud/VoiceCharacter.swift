//
//  VoiceCharacter.swift
//  MaryVoice
//
//  The catalog of Mistral TTS characters. A character is a slug prefix plus
//  the emotions it can render; the wire voice_id is "<prefix>_<emotion>".
//

import Foundation

public struct VoiceCharacter: Sendable, Identifiable, Hashable {
    /// Slug prefix, e.g. "fr_marie" — this is what settings persists.
    public let id: String
    public let displayName: String
    public let emotions: Set<MarieEmotion>

    public init(id: String, displayName: String, emotions: Set<MarieEmotion>) {
        self.id = id
        self.displayName = displayName
        self.emotions = emotions
    }

    /// The Mistral `voice_id` for this character speaking with `emotion`.
    public func voiceID(for emotion: MarieEmotion) -> String {
        "\(id)_\(emotion.rawValue)"
    }

    public static let marie = VoiceCharacter(
        id: "fr_marie",
        displayName: "Marie",
        emotions: [.neutral, .sad, .happy, .excited, .curious, .angry])

    public static let all: [VoiceCharacter] = [.marie]

    /// Lookup by persisted id; unknown ids fall back to Marie so a stale
    /// config value can never produce an invalid voice_id.
    public static func named(_ id: String) -> VoiceCharacter {
        all.first { $0.id == id } ?? .marie
    }
}

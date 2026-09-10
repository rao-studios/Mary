//
//  SpeechRouter.swift
//  MaryVoice
//
//  WHAT: One turn's BrainEvents → speaker (local tokens vs server PCM).
//  IN:   VoicePipeline / SendText / Sewn probe
//  OUT:  KokoroStreamSpeaker (feed / remote PCM / softStop / flush)
//  PIN:  Mid-turn .server→.local re-baselines so local never re-reads server text.
//

import Foundation

public struct SpeechRouter: Sendable {

    /// True once any server PCM was enqueued this turn.
    public private(set) var didUseRemoteAudio = false
    /// True once text was fed to the local speaker since the last retraction.
    /// PIN: `finish()` flushes only when this is true — retraction + prose
    /// re-sets it; retraction + silence leaves it false (no phantom `.started`).
    public private(set) var didFeedSpeaker = false

    private var speechSource = SpeechSource.local
    /// Prefix already voiced by the server or retracted; local speaks after it.
    private var speakerBaseline = ""
    private let speaker: KokoroStreamSpeaker
    /// Floor lease for this turn — checked inside the speaker actor, not here.
    private let speakerLease: UUID?
    private let holdWindowNanoseconds: UInt64

    public var isLocalSpeech: Bool { speechSource == .local }

    public init(
        speaker: KokoroStreamSpeaker,
        speakerLease: UUID? = nil,
        holdWindowNanoseconds: UInt64 = KokoroStreamSpeaker.takeoverHoldNanoseconds
    ) {
        self.speaker = speaker
        self.speakerLease = speakerLease
        self.holdWindowNanoseconds = holdWindowNanoseconds
    }

    /// After appending a token. No-op while source is `.server`.
    public mutating func consumeToken(accumulated: String) async {
        guard speechSource == .local else { return }
        // Open the takeover hold on the first spoken token (policy, not chunk size).
        if !didFeedSpeaker,
           !(await speaker.holdSynthesis(for: holdWindowNanoseconds, lease: speakerLease)) {
            return
        }
        guard await speaker.feed(
            String(accumulated.dropFirst(speakerBaseline.count)),
            lease: speakerLease
        ) else { return }
        didFeedSpeaker = true
    }

    /// Retract everything said this turn; next yields replace it. PIN: `softStop`,
    /// not `feed`'s baseline-reset (that swallows; stale line still speaks at flush).
    public mutating func consumeRetractSpeech(accumulated: String) async {
        guard await speaker.softStop(lease: speakerLease) else { return }
        speakerBaseline = accumulated
        didFeedSpeaker = false
    }

    public mutating func consumeSpeechSource(_ source: SpeechSource, accumulated: String) {
        // Baseline advances only when server audio actually played.
        if source == .local, speechSource == .server, didUseRemoteAudio {
            speakerBaseline = accumulated
        }
        speechSource = source
    }

    public mutating func consumeAudioChunk(_ pcm: Data, sampleRate: Double) async {
        guard await speaker.enqueueRemotePCM(
            pcm,
            sampleRate: sampleRate,
            lease: speakerLease
        ) else { return }
        didUseRemoteAudio = true
    }

    /// End of turn: drain remote if it played; flush local only if text reached it.
    /// Empty flush would emit spurious `.started`. OUT: `endTurnUnspoken` if silent.
    public func finish() async {
        if didUseRemoteAudio {
            guard await speaker.endRemoteAudio(lease: speakerLease) else { return }
        }
        if didFeedSpeaker {
            _ = await speaker.flush(lease: speakerLease)
        } else {
            // Turn ended without flush — clear the takeover hold for the next turn.
            _ = await speaker.endTurnUnspoken(lease: speakerLease)
        }
    }
}

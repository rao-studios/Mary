//
//  KokoroStreamSpeakerModels.swift
//  MaryVoice
//
//  WHAT: RingBuffer, RetiredOutputAudioGraph, SpeakerEvent, ChunkPolicy.
//  IN:   KokoroStreamSpeaker.swift → this (sibling split)
//  OUT:  VoicePipeline / SpeechRouter / probes
//

import AVFoundation
import Foundation
import NaturalLanguage

/// Bounded async slot tracker. Caps pre-queued PCM on the player node.
/// acquire() before schedule; release() on playback done; drain() after text ends.
actor RingBuffer {
    private let capacity: Int
    private var available: Int
    private var inFlight:  Int = 0

    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiter: CheckedContinuation<Void, Never>?

    init(capacity: Int) {
        self.capacity  = capacity
        self.available = capacity
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            inFlight  += 1
        } else {
            await withCheckedContinuation { slotWaiters.append($0) }
            inFlight += 1
        }
    }

    func release() {
        inFlight -= 1
        if inFlight == 0 {
            drainWaiter?.resume()
            drainWaiter = nil
        }
        if let waiter = slotWaiters.first {
            slotWaiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }

    func drain() async {
        guard inFlight > 0 else { return }
        await withCheckedContinuation { drainWaiter = $0 }
    }

    /// Nothing scheduled on the player right now. Distinct from drain() — stream may still be open.
    var isIdle: Bool { inFlight == 0 }
}

/// Sendable envelope for a stopped CoreAudio output graph. Never touched again;
/// only extends lifetime past late I/O-unit callbacks.
final class RetiredOutputAudioGraph: @unchecked Sendable {
    private let engine: AVAudioEngine?
    private let player: AVAudioPlayerNode?

    init(engine: AVAudioEngine?, player: AVAudioPlayerNode?) {
        self.engine = engine
        self.player = player
    }

    func keepAlive() {
        withExtendedLifetime((engine, player)) {}
    }
}

// MARK: - SpeakerEvent

/// Observable moments in the text→speech stream.
public enum SpeakerEvent: Sendable {
    /// A sentence batch was handed to synthesis.
    case chunkQueued(String)
    /// That batch's audio entered the playback queue.
    case chunkScheduled(String)
    /// Playback began (first chunk of a stream).
    case started
    /// Playback provisionally paused (possible barge-in onset).
    case paused
    /// The pause turned out to be noise — playback resumed.
    case resumed
    /// Room quiet while the text stream is still open. Consumer: VoicePipeline barge-in onset.
    case audioIdle
    /// All queued audio finished playing.
    case drained
    /// Playback was hard-stopped (barge-in).
    case stopped
    /// The pronunciation trace for a chunk that just synthesized.
    case pronunciation(PronunciationReport)
    /// Chunk synthesis threw past every retry/fallback. Consumer: host status.
    case chunkFailed(text: String, reason: String)
}

/// How later chunks may grow after the first. First chunk keeps ctor limits
/// (takeover arithmetic). Kokoro's 30-word cap must not grow; cloud may.
public struct ChunkPolicy: Sendable, Equatable {
    public let laterSentencesPerChunk: Int
    public let laterMaxWords: Int

    public init(laterSentencesPerChunk: Int, laterMaxWords: Int) {
        self.laterSentencesPerChunk = laterSentencesPerChunk
        self.laterMaxWords = laterMaxWords
    }

    /// On-device: identical to first-chunk limits — no growth.
    public static let onDevice = ChunkPolicy(laterSentencesPerChunk: 2, laterMaxWords: 30)
    /// Cloud: longer batches, fewer seams.
    public static let cloud = ChunkPolicy(laterSentencesPerChunk: 4, laterMaxWords: 60)
}

//
//  KokoroStreamSpeakerModels.swift
//  MaryVoice
//
//  Split out of KokoroStreamSpeaker.swift (docs/DECOMPOSITION.md
//  Wave 2) — pure relocation, no declaration changed.
//

import AVFoundation
import Foundation
import NaturalLanguage

/// Bounded async slot tracker that backs-pressures synthesis to at most
/// `capacity` pre-queued PCM buffers on the player node at any time.
///
///   acquire() — called before scheduling a buffer; suspends if all slots occupied
///   release() — called from the buffer's playback completion handler; frees a slot
///   drain()   — called after the text stream ends; suspends until in-flight count hits 0
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

    /// Nothing is scheduled on the player node right now. Distinct from
    /// `drain()`: the text stream may still be open, so this is "the room
    /// went quiet", not "the turn is over".
    var isIdle: Bool { inFlight == 0 }
}

/// Sendable ownership envelope for a stopped CoreAudio output graph. The
/// contained AVFoundation objects are never touched again; the wrapper only
/// extends their lifetime past any late I/O-unit callbacks.
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
    /// Every scheduled buffer has played out, but the text stream is still
    /// OPEN — the turn continues (a Skill invocation, a slow model, a lane still
    /// thinking) with nothing audible. Not `.drained`: the stream has not
    /// ended. Consumers that boost a threshold "because Mary is speaking"
    /// must un-boost here — see VoicePipeline's barge-in onset.
    case audioIdle
    /// All queued audio finished playing.
    case drained
    /// Playback was hard-stopped (barge-in).
    case stopped
    /// The pronunciation trace for a chunk that just synthesized.
    case pronunciation(PronunciationReport)
    /// A chunk's synthesis threw PAST every engine-level retry and fallback —
    /// the sentence produced no audio at all. Emitted instead of the old
    /// silent `try? … continue`, which made the line vanish with no trace:
    /// the host surfaces it so a skipped sentence is never a mystery.
    case chunkFailed(text: String, reason: String)
}

/// HOW CHUNKS MAY GROW AFTER THE FIRST — backend-aware, because the caps
/// mean different things per engine. The FIRST chunk always uses the ctor
/// limits (fast first audio; the takeover arithmetic is pinned to it); later
/// chunks of the same pipeline may batch more sentences so a long passage
/// has fewer seams. Kokoro's 30-word cap is a MODEL limit (~242 token
/// slots) and must not grow; cloud engines have no such ceiling.
public struct ChunkPolicy: Sendable, Equatable {
    public let laterSentencesPerChunk: Int
    public let laterMaxWords: Int

    public init(laterSentencesPerChunk: Int, laterMaxWords: Int) {
        self.laterSentencesPerChunk = laterSentencesPerChunk
        self.laterMaxWords = laterMaxWords
    }

    /// On-device: identical to the first-chunk limits — no growth.
    public static let onDevice = ChunkPolicy(laterSentencesPerChunk: 2, laterMaxWords: 30)
    /// Cloud: longer batches, fewer seams, one prosody arc per batch.
    public static let cloud = ChunkPolicy(laterSentencesPerChunk: 4, laterMaxWords: 60)
}

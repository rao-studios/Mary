//
//  SpeechRouter.swift
//  MaryVoice
//
//  Routes one turn's BrainEvents to the speaker: local tokens feed the text
//  pipeline, server PCM feeds the remote seam, and a mid-turn .server→.local
//  switch re-baselines so the local voice never re-reads server-voiced text.
//
//  This is the single home for the speech-routing state machine shared by
//  VoicePipeline, the chat SendText reducer, and the Seer probe — speech
//  concerns only; transcript, UI, and timing stay with the caller.
//

import Foundation

public struct SpeechRouter: Sendable {

    /// True once any server PCM was enqueued this turn.
    public private(set) var didUseRemoteAudio = false
    /// True once any text was fed to the local speaker SINCE THE LAST
    /// RETRACTION — the turn, for every turn that never retracts.
    ///
    /// THE RESET IS THE MECHANISM, not bookkeeping. `finish()` flushes only
    /// when this is true, and that single flag now answers both halves of the
    /// takeover: a retraction FOLLOWED by replacement prose sets it true again
    /// on the next token, so the replacement flushes (the trap — a takeover
    /// that never flushed would substitute silence for a correction); a
    /// retraction followed by NOTHING leaves it false, so no empty flush runs
    /// and no phantom `.started` fires. See `finish()`.
    public private(set) var didFeedSpeaker = false

    private var speechSource = SpeechSource.local
    /// Prefix of the accumulated text already voiced by the server, or
    /// retracted from the local voice; the local speaker only ever speaks what
    /// comes after it.
    private var speakerBaseline = ""
    private let speaker: KokoroStreamSpeaker
    /// The speaker-owned floor lease for this turn.  It is deliberately
    /// threaded into every mutating operation: a caller-side `Task` check
    /// cannot close the gap between this router and the speaker actor.
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

    /// Call after appending a token to the turn's accumulated text.
    /// No-op while the source is `.server` (tokens are transcript-only).
    public mutating func consumeToken(accumulated: String) async {
        guard speechSource == .local else { return }
        // THE TAKEOVER WINDOW IS OPENED HERE, on the turn's first spoken token,
        // and it is opened as POLICY. Until this call existed the window was a
        // coincidence of chunk sizing (see `holdSynthesis`), and a later
        // latency change would have closed it with no test failing.
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

    /// THE TAKEOVER: retract everything this turn has said and start again from
    /// `accumulated`. Whatever the brain yields next is the whole spoken reply;
    /// if it yields nothing, the turn is silent.
    ///
    /// `softStop()` IS THE PRIMITIVE, and `feed`'s baseline-reset rule is NOT.
    /// Handing `feed` a non-extending string sets `lastSeenString` and returns
    /// — a SWALLOW rather than a substitution: `rawBuffer` still holds the old
    /// text, so the replacement is silent AND the stale line still speaks at
    /// flush, which is the worst of both. `softStop()` clears the buffers, the
    /// batch and the staged hold, and lets audio already in flight drain to a
    /// sentence boundary instead of cutting a word in half.
    ///
    /// The baseline advances to `accumulated` for the same reason it does on a
    /// server→local hand-back: the speaker is a length-diffing API, and the
    /// replacement's tokens arrive as a growing accumulation that still carries
    /// the retracted prose on its front.
    public mutating func consumeRetractSpeech(accumulated: String) async {
        guard await speaker.softStop(lease: speakerLease) else { return }
        speakerBaseline = accumulated
        didFeedSpeaker = false
    }

    public mutating func consumeSpeechSource(_ source: SpeechSource, accumulated: String) {
        // Baseline only advances when server audio actually played — if none
        // arrived, the local voice must speak the whole reply from the top.
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

    /// End of turn: drain the remote pipeline if it played, and flush the
    /// text pipeline only when text actually reached it — an empty flush
    /// still runs the pipeline and emits a spurious .started, which flashed
    /// a phantom "speaking" state on silent action turns (zero tokens).
    /// Non-mutating so callers may copy the router into a detached task.
    ///
    /// A COMPLETED FAST ACTION REACHES THIS WITH `didFeedSpeaker == false` and
    /// takes the same road a zero-token action turn always did: no flush, no
    /// audio, no `.started`, and the transcript's Ability | Skill badges are the reply.
    /// That is the user's decision, verbatim — "a completed fast action stays
    /// silent" — expressed through the guard that already existed for it
    /// rather than through a second, parallel one.
    public func finish() async {
        if didUseRemoteAudio {
            guard await speaker.endRemoteAudio(lease: speakerLease) else { return }
        }
        if didFeedSpeaker {
            _ = await speaker.flush(lease: speakerLease)
        } else {
            // …but the TURN still ended, and the speaker is shared across
            // turns. `flush()` is what normally tells it so; a turn that never
            // flushes has to say it another way, or the takeover hold this turn
            // armed stays armed and the NEXT turn silently gets none. See
            // `KokoroStreamSpeaker.endTurnUnspoken`.
            _ = await speaker.endTurnUnspoken(lease: speakerLease)
        }
    }
}

//
//  KokoroStreamSpeaker.swift
//  MaryVoice
//
//  Pipes streaming LLM output to Kokoro TTS via a circular PCM buffer.
//  Faithful port of SeerTTS/KokoroTTSDemo's TTSStreamProcessor with three
//  deliberate changes:
//    1. The @MainActor singleton becomes an injectable actor.
//    2. `hardStop()` — the original `stop()` only cancelled the pipeline Task,
//       so already-scheduled PCM kept playing. The speaker now retains the
//       live player/engine and silences them immediately (what barge-in needs).
//    3. An `events()` tap so the pipeline/UI/probe can watch chunks move
//       through synthesis and playback.
//
//  Usage:
//    let speaker = KokoroStreamSpeaker(engine: kokoro)
//    await speaker.feed("Sure")           // growing accumulated string
//    await speaker.feed("Sure, I can")
//    await speaker.feed("Sure, I can help you.")
//    await speaker.flush()                // speak remainder and wait for drain
//

import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - RingBuffer

/// Collects incoming LLM token strings, extracts complete sentences, sanitizes
/// markdown, and pipelines synthesis with playback via a ring buffer.
///
/// Architecture
/// ────────────
///   feed() → rawBuffer → [sentence extraction + markdown sanitization] → textStream
///
///   Stage A (detached):
///     textStream → synthesizer.synthesizeWaveform() → waveformStream
///
///   Stage B (ring-buffered playback):
///     waveformStream → ring.acquire() → scheduleBuffer()
///                                             ↓ (completion)
///                                       ring.release()
///
// MARK: - KokoroStreamSpeaker

/// Chunking: NLTokenizer(.sentence) extracts only fully-terminated sentences
/// from the buffer. The incomplete trailing sentence stays buffered until more
/// tokens arrive. A hard word cap splits pathologically long sentences so
/// the model never receives more tokens than its context window allows.
public actor KokoroStreamSpeaker {

    /// The shared speaker has more than one potential producer: a text turn,
    /// a detached follow-up, and the live voice pipeline.  A caller-side
    /// cancellation check is not enough to arbitrate those writers because
    /// the check and `feed` are separate actor hops.  The floor lease is
    /// therefore checked *inside this actor*, at the mutation point.
    ///
    /// Callers mint the UUID before they start work.  A fresh claim revokes
    /// every operation carrying an older id; an unleased legacy call is only
    /// admitted while nobody has claimed the floor.  This keeps probes and
    /// isolated unit fixtures source-compatible without giving them a way to
    /// mutate a live application turn.
    // MARK: - Public

    public private(set) var isSpeaking = false

    public var style: TTSSpeechStyle

    /// Pre-queued PCM buffer slots. 3 = playing + queued + synthesising.
    public let ringDepth: Int

    /// Number of complete sentences to accumulate before yielding a synthesis chunk.
    /// 2–3 feels natural; lower = more responsive but choppier gaps between chunks.
    public let sentencesPerChunk: Int

    /// The shipped chunk size, named rather than repeated as a literal in three
    /// initialiser defaults — because the takeover's bound rests on it and a
    /// number that only exists as a default argument cannot be reasoned about
    /// from another package.
    public static let defaultSentencesPerChunk = 2

    /// HOW MANY SENTENCES OF TEXT MUST LAND BEFORE THE FIRST AUDIO CAN EXIST:
    /// `defaultSentencesPerChunk` complete sentences, PLUS one more to prove the
    /// last of them ended — `extractSentences` only accepts a sentence that
    /// finishes strictly before the buffer does. 2 + 1 = 3.
    ///
    /// THIS IS THE TAKEOVER WINDOW, WRITTEN DOWN. A short acknowledgement ("On
    /// it — putting that on now.") is two sentences, so it is still
    /// un-synthesized text in `rawBuffer` when the Skill execution lane joins holding the
    /// completed outcomes, which is exactly what lets `.retractSpeech` replace
    /// it instead of talking over it. That property used to be a COINCIDENCE of
    /// chunk sizing; `holdSynthesis(for:)` below makes it policy, and this
    /// constant makes the arithmetic visible to the brain that depends on it.
    public static let sentencesBeforeFirstAudio = defaultSentencesPerChunk + 1

    /// Hard word-count ceiling per chunk. Kokoro's 10s model has ~242 token slots;
    /// at ~6 phoneme tokens/word that's ~40 words. 30 is conservative to leave headroom.
    /// When adding a sentence would push the batch over this limit the current batch
    /// is flushed first so nothing gets truncated mid-sentence.
    public let maxWordsPerChunk: Int

    // MARK: - Private

    /// Swappable via `setSynthesizer`; a change applies to the next pipeline
    /// run — a turn already speaking finishes on the backend it started with.
    private var synthesizer: any SpeechSynthesizer

    /// Raw accumulated text, possibly containing markdown and partial sentences.
    private var rawBuffer: String = ""
    private var lastSeenString: String = ""

    /// The only writer currently allowed to mutate the speaker.  `nil` is
    /// the legacy/standalone mode used by probes and isolated tests.
    private var activeFloorLease: UUID?
    /// A voice session reserves the floor even while it is listening.  A
    /// held text follow-up must not wake into that silent gap and speak over
    /// the microphone pipeline.
    private var voiceFloorReserved = false
    /// Hard resets invalidate asynchronous pipeline tails as well as direct
    /// operations.  A cancelled old `flush()` can resume after a new turn has
    /// begun; it must not reset the new turn's diff baseline or speaking bit.
    private var hardResetEpoch: UInt64 = 0

    private var textContinuation: AsyncStream<String>.Continuation?
    private var pipelineTask:     Task<Void, Never>?
    /// Stage A synthesis task — detached, so hardStop() must cancel it
    /// explicitly to abort an in-flight cloud request.
    private var synthTask:        Task<Void, Never>?

    /// Pending sentences and their running count waiting to fill the current chunk.
    private var sentenceBatch: String = ""
    private var sentenceBatchCount: Int = 0

    /// Live playback nodes — retained so hardStop() can silence them instantly.
    private var activeEngine: AVAudioEngine?
    private var activePlayer: AVAudioPlayerNode?

    /// `AVAudioEngine.stop()` has no public callback-drained barrier. Keep a
    /// stopped output graph alive through CoreAudio's asynchronous I/O-unit
    /// retirement, just as MicCapture does for input graphs. The player is
    /// retained with its engine because completion callbacks target both.
    private static let audioRetirementQueue = DispatchQueue(
        label: "mary.speaker.engine-retirement")
    private static let audioRetirementGrace: TimeInterval = 10

    /// Deterministic playback seam used only by package tests. The closure is
    /// awaited in the same place production waits for an
    /// `AVAudioPlayerNode` `.dataPlayedBack` callback, which lets lifecycle
    /// tests exercise real, non-empty PCM without depending on the machine's
    /// current output device. Nil in every public initializer/production use.
    typealias DataPlayedBackDriver = @Sendable (
        _ samples: [Float], _ sampleRate: Double, _ text: String
    ) async -> Void
    private var dataPlayedBackDriverForTesting: DataPlayedBackDriver?

    /// Sentence-boundary stop machinery: when requested, the first buffer
    /// completion stops the player (silencing anything still scheduled) and
    /// the drain wakes the waiters. See softStop().
    private var softStopRequested = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// THE TAKEOVER HOLD — chunks that reached a batch boundary while the hold
    /// was armed, staged in order and released together. See holdSynthesis().
    private var synthesisHoldExpiry: DispatchTime?
    private var heldChunks: [String] = []
    private var holdReleaseTask: Task<Void, Never>?
    /// ONE HOLD PER TURN. A retraction's REPLACEMENT is never held again — the
    /// lane the hold was waiting for has already spoken, and holding the
    /// correction behind the same window it bought would delay the one sentence
    /// this whole mechanism exists to deliver. Cleared by `flush()` (the turn
    /// ended) and `hardStop()` (the turn was destroyed), deliberately NOT by
    /// `softStop()` (the turn continues, under new text).
    private var didHoldSynthesis = false

    /// Event tap subscribers.
    private var eventContinuations: [UUID: AsyncStream<SpeakerEvent>.Continuation] = [:]

    // MARK: - Init

    public init(
        synthesizer: any SpeechSynthesizer,
        style: TTSSpeechStyle = .neutral,
        ringDepth: Int = 3,
        sentencesPerChunk: Int = KokoroStreamSpeaker.defaultSentencesPerChunk,
        maxWordsPerChunk: Int = 30
    ) {
        self.synthesizer       = synthesizer
        self.style             = style
        self.ringDepth         = ringDepth
        self.sentencesPerChunk = sentencesPerChunk
        self.maxWordsPerChunk  = maxWordsPerChunk
    }

    public init(
        engine: KokoroEngine,
        style: TTSSpeechStyle = .neutral,
        ringDepth: Int = 3,
        sentencesPerChunk: Int = KokoroStreamSpeaker.defaultSentencesPerChunk,
        maxWordsPerChunk: Int = 30
    ) {
        self.init(
            synthesizer: engine,
            style: style,
            ringDepth: ringDepth,
            sentencesPerChunk: sentencesPerChunk,
            maxWordsPerChunk: maxWordsPerChunk)
    }

    public func setStyle(_ style: TTSSpeechStyle) {
        self.style = style
    }

    /// Applies to the next pipeline run; a reply already speaking finishes
    /// on its current backend. Never interrupts live audio.
    public func setSynthesizer(_ synthesizer: any SpeechSynthesizer) {
        self.synthesizer = synthesizer
    }

    /// The growth policy rides the synthesizer choice — the host knows which
    /// backend it installed and what its chunks may grow to.
    public func setSynthesizer(_ synthesizer: any SpeechSynthesizer, policy: ChunkPolicy) {
        self.synthesizer = synthesizer
        self.chunkPolicy = policy
    }

    func setDataPlayedBackDriverForTesting(_ driver: DataPlayedBackDriver?) {
        dataPlayedBackDriverForTesting = driver
    }

    /// Nil = no growth: every chunk uses the ctor limits, today's behavior.
    private var chunkPolicy: ChunkPolicy?
    /// Chunks queued since this pipeline began — index 0 keeps the fast-start
    /// limits, later indices may grow per `chunkPolicy`.
    private var chunksQueuedThisPipeline = 0

    // MARK: - Shared speaker floor

    /// Claim the shared speaker for a text-mode writer.  This is intentionally
    /// refused while the voice session owns the floor, including its quiet
    /// listening state.
    @discardableResult
    public func claimTextFloor(_ lease: UUID, hardStop: Bool = true) -> Bool {
        guard !voiceFloorReserved else { return false }
        claimFloor(lease, hardStop: hardStop)
        return true
    }

    /// Transfer text playback from a known current writer. Detached work uses
    /// this instead of the unconditional user-boundary claim: if a new user
    /// turn has already replaced `expectedLease`, an old follow-up's delayed
    /// actor hop cannot steal the speaker back. An idle speaker is also a
    /// valid handoff target because a completed primary turn releases its
    /// lease after its drain.
    @discardableResult
    public func replaceTextFloor(
        _ lease: UUID,
        replacing expectedLease: UUID?,
        allowingIdle: Bool = true
    ) -> Bool {
        guard !voiceFloorReserved else { return false }
        guard activeFloorLease == expectedLease
                || (allowingIdle && activeFloorLease == nil)
        else { return false }
        claimFloor(lease, hardStop: false)
        return true
    }

    /// Claim the speaker for the live voice pipeline.  A voice session owns
    /// the floor between utterances too, so a delayed text follow-up cannot
    /// fill the silent listening gap.
    @discardableResult
    public func claimVoiceFloor(_ lease: UUID, hardStop: Bool = true) -> Bool {
        voiceFloorReserved = true
        claimFloor(lease, hardStop: hardStop)
        return true
    }

    /// Compare-and-swap handoff within an already-active voice session. A
    /// proactive voice follow-up may yield the current reply, but it may not
    /// reclaim the speaker after a newer voice utterance has taken it. Unlike
    /// text mode, voice never releases its session floor between utterances,
    /// so an idle speaker is NOT a valid handoff target: that moment belongs
    /// to a barge-in or session shutdown, not an old detached routine.
    @discardableResult
    public func replaceVoiceFloor(
        _ lease: UUID,
        replacing expectedLease: UUID
    ) -> Bool {
        guard voiceFloorReserved else { return false }
        guard activeFloorLease == expectedLease else { return false }
        claimFloor(lease, hardStop: false)
        return true
    }

    /// Release voice mode when the microphone session ends.  This is a hard
    /// boundary: stale voice tasks may not resume into the next text turn.
    public func leaveVoiceFloor() {
        voiceFloorReserved = false
        invalidateAndHardStop()
    }

    /// Conditional release for a failed/stale session start. The teardown
    /// fence uses the unconditional form after draining ownership operations;
    /// an individual start continuation must not release a newer session that
    /// claimed this shared speaker while its actor hop was pending.
    @discardableResult
    public func leaveVoiceFloor(lease: UUID) -> Bool {
        guard voiceFloorReserved, activeFloorLease == lease else { return false }
        voiceFloorReserved = false
        invalidateAndHardStop()
        return true
    }

    /// A cheap preflight for callers that want to avoid work.  Correctness
    /// never relies on it; every mutating API below checks the same lease
    /// again inside this actor.
    public func ownsFloor(_ lease: UUID) -> Bool {
        accepts(lease)
    }

    /// Release a completed writer without interrupting already-drained audio.
    /// The conditional guard is important: an old finalizer must never clear a
    /// newer follow-up or user turn that claimed the speaker while it awaited
    /// `flush()`.
    @discardableResult
    public func releaseFloor(_ lease: UUID) -> Bool {
        guard accepts(lease) else { return false }
        activeFloorLease = nil
        return true
    }

    private func claimFloor(_ lease: UUID, hardStop: Bool) {
        activeFloorLease = lease
        if hardStop {
            hardResetEpoch &+= 1
            hardStopContents()
        }
    }

    private func accepts(_ lease: UUID?) -> Bool {
        guard let lease else { return activeFloorLease == nil }
        return activeFloorLease == lease
    }

    private func invalidateAndHardStop() {
        activeFloorLease = nil
        hardResetEpoch &+= 1
        hardStopContents()
    }

    // MARK: - Events

    /// A new stream of speaker events for each subscriber.
    public func events() -> AsyncStream<SpeakerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SpeakerEvent>.makeStream(bufferingPolicy: .unbounded)
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeEventContinuation(id) }
        }
        return stream
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func emit(_ event: SpeakerEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func emitPronunciation(_ report: PronunciationReport, epoch: UInt64) {
        guard epoch == hardResetEpoch else { return }
        emit(.pronunciation(report))
    }

    /// How many chunks Stage A may hold in flight. Two: enough that one slow
    /// chunk never runs the player dry, small enough that a barge-in wastes
    /// at most one sentence of cloud synthesis.
    static let prefetchDepth = 2

    private func emitChunkFailed(text: String, reason: String, epoch: UInt64) {
        guard epoch == hardResetEpoch else { return }
        // A cancelled chunk is the pipeline being torn down, not a lost
        // sentence — barge-in must not read as a failure.
        guard !reason.localizedCaseInsensitiveContains("cancel") else { return }
        emit(.chunkFailed(text: text, reason: reason))
    }

    // MARK: - Public API

    /// Feed the full accumulated string from the LLM on each token arrival.
    ///
    ///     feed("He")
    ///     feed("Hello")
    ///     feed("Hello World. How are you?")
    ///
    /// Diffs against the previous call internally; only the new suffix is appended.
    ///
    /// THE BASELINE BELONGS TO ONE WRITER. This is a length-diffing API, and
    /// `softStop()`/`hardStop()`/`flush()` reset `lastSeenString` when a new
    /// writer takes the floor. Without the prefix check below, a SUPERSEDED
    /// turn resuming from its own `accumulated` — a suspended
    /// `router.consumeToken` landing after another writer took over — would
    /// splice a length-offset SUFFIX of turn N's passage into turn N+1's live
    /// stream. That is the literal audio form of the reported bug: "the result
    /// pipes in later and appends to the response that answered the new
    /// query." A string that does not extend what this speaker has already
    /// seen is not a delta — it is a foreign writer. RESET the baseline to it
    /// and speak nothing: the foreign text never plays, and the rightful
    /// writer re-synchronizes on its very next (monotonically growing) feed.
    /// Returns false when a newer floor has already taken the speaker.  This
    /// check lives beside the diff baseline so an old writer can never refill
    /// `rawBuffer` after a new turn's hard stop.
    @discardableResult
    public func feed(_ fullString: String, lease: UUID? = nil) -> Bool {
        guard accepts(lease) else { return false }
        guard fullString.hasPrefix(lastSeenString) else {
            lastSeenString = fullString
            return true
        }
        guard fullString.count > lastSeenString.count else { return true }
        let delta = String(fullString.suffix(fullString.count - lastSeenString.count))
        lastSeenString = fullString
        rawBuffer += delta
        extractSentences()
        return true
    }

    /// Flush remaining buffered text and wait for all queued audio to finish.
    ///
    /// A flush has an await at its tail.  Re-checking its lease after that
    /// await is what prevents an old drain from clearing `lastSeenString` or
    /// `didHoldSynthesis` under audio the next turn has already fed.
    @discardableResult
    public func flush(lease: UUID? = nil) async -> Bool {
        guard accepts(lease) else { return false }
        let epoch = hardResetEpoch
        // The turn is over, so whatever the hold was waiting for has happened:
        // the lane joined, detached, or blew its grace. Staged chunks go out
        // FIRST, in order, ahead of the tail below.
        releaseSynthesisHold()

        // Drain any remaining raw buffer
        let remaining = sanitize(rawBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        rawBuffer = ""

        // Merge any partial sentence batch with leftover raw text
        var toSpeak = sentenceBatch
        sentenceBatch      = ""
        sentenceBatchCount = 0
        if !remaining.isEmpty {
            toSpeak = toSpeak.isEmpty ? remaining : toSpeak + " " + remaining
        }

        if !toSpeak.isEmpty {
            ensurePipeline()
            emit(.chunkQueued(toSpeak))
            textContinuation?.yield(toSpeak)
        }
        textContinuation?.finish()
        let task = pipelineTask
        pipelineTask = nil
        textContinuation = nil
        await task?.value
        guard accepts(lease), epoch == hardResetEpoch else { return false }
        lastSeenString = ""
        didHoldSynthesis = false
        return true
    }

    // MARK: - The takeover hold

    /// HOW LONG THE SPEAKER WAITS FOR THE SKILL EXECUTION LANE BEFORE IT COMMITS A WORD.
    ///
    /// 250 ms, and it is not a new number: it is `MaryBrain`'s non-action
    /// lane join grace — how long a turn holds for its Skill execution lane before the
    /// lane detaches into a routine. Holding for exactly that window means the
    /// speaker commits nothing while the outcome could still arrive in-turn,
    /// and commits immediately once it cannot. `TakeoverTests` pins the two
    /// together so they cannot drift apart in silence.
    ///
    /// An ACTION turn has no voice lane at all (no Lane A, no tokens, nothing
    /// to hold), so the five-second action grace never applies here.
    public static let takeoverHoldNanoseconds: UInt64 = 250_000_000

    /// HOLD SYNTHESIS FOR THE TAKEOVER WINDOW — the property, stated, instead
    /// of the side effect that used to provide it.
    ///
    /// Until this existed the window was an ACCIDENT: `sentencesPerChunk = 2`
    /// plus "a sentence only counts once something follows it" means first
    /// audio needs THREE complete sentences, while the prompt tells her to keep
    /// an acknowledgement to "a few words" — so every acknowledgement fell
    /// below the threshold and sat in `rawBuffer` until `flush()`, which runs
    /// after `.completed`. The takeover worked because the speaker happened to
    /// be slow. That is not a guarantee, it is a coincidence that a future
    /// `firstChunkSentences = 1` would delete without touching a line of the
    /// brain — and the staleness bug would come back with no test failing.
    ///
    /// While held, complete sentences still batch exactly as they do normally;
    /// only the handoff to synthesis waits, so chunk boundaries and the word
    /// cap are byte-identical to an unheld stream. A retraction DISCARDS what
    /// is staged, which is what makes "the stale text never reaches synthesis"
    /// a guarantee rather than a hope.
    ///
    /// Armed by `SpeechRouter` on a turn's first local token and by nobody
    /// else: proactive playback (follow-ups, progress marks) speaks into a room
    /// that is already quiet and has no lane to wait for.
    ///
    /// WHAT IT COSTS TODAY: NOTHING, and that is on purpose for this round. At
    /// the shipped `sentencesPerChunk = 2` an acknowledgement produces no chunk
    /// at all, so there is nothing to stage; and a reply long enough to produce
    /// one takes far longer than 250 ms to stream, so the window has already
    /// expired when it arrives. The mechanism is here so the property is
    /// STATED, plumbed and pinned before the latency work that will make it
    /// load-bearing — not to change any timing now.
    ///
    /// WHAT THE LATENCY WORK MUST RE-EXAMINE, written down while it is fresh:
    /// the window is measured from the FIRST TOKEN, not from the lane's spawn,
    /// because that is the first moment the speaker learns a turn exists. So it
    /// covers the takeover only while Lane A streams fast. Whoever adopts
    /// `firstChunkSentences = 1` has to decide whether this window should slide
    /// with the tokens instead — an acknowledgement would then become one whole
    /// chunk, and a window that expired mid-utterance would commit it.
    @discardableResult
    func holdSynthesis(for nanoseconds: UInt64, lease: UUID? = nil) -> Bool {
        // `false` means the writer lost the floor. An existing hold belongs
        // to this same turn and is intentionally a successful no-op: a
        // retraction's replacement must keep streaming behind the window it
        // already bought rather than being mistaken for a stale writer.
        guard accepts(lease) else { return false }
        guard !didHoldSynthesis else { return true }
        didHoldSynthesis = true
        synthesisHoldExpiry = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
        let epoch = hardResetEpoch
        // A SELF-RELEASING HOLD. The expiry is also checked on every chunk, but
        // a stream that goes quiet inside the window (a model deliberating
        // mid-reply) would otherwise leave staged audio sitting until the next
        // token — silence bought by the mechanism that exists to protect
        // speech.
        holdReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.releaseSynthesisHold(epoch: epoch)
        }
        return true
    }

    private var isSynthesisHeld: Bool {
        guard let expiry = synthesisHoldExpiry else { return false }
        return DispatchTime.now() < expiry
    }

    /// Everything the hold staged moves to synthesis, in arrival order.
    func releaseSynthesisHold(epoch: UInt64? = nil) {
        if let epoch, epoch != hardResetEpoch { return }
        holdReleaseTask?.cancel()
        holdReleaseTask = nil
        synthesisHoldExpiry = nil
        guard !heldChunks.isEmpty else { return }
        ensurePipeline()
        let staged = heldChunks
        heldChunks = []
        for chunk in staged {
            emit(.chunkQueued(chunk))
            textContinuation?.yield(chunk)
        }
    }

    /// The hold and everything it staged, DROPPED. Only the retraction paths
    /// call this, and it is exactly right for them: what the hold stages is by
    /// definition text that has not been synthesized, and a retraction's whole
    /// claim is that such text is never spoken.
    private func discardSynthesisHold() {
        holdReleaseTask?.cancel()
        holdReleaseTask = nil
        synthesisHoldExpiry = nil
        heldChunks = []
    }

    /// A TURN THAT ENDED WITHOUT SPEAKING STILL ENDED — and until this existed,
    /// the one turn shape this round INTRODUCED was the one that leaked.
    ///
    /// `flush()` and `hardStop()` were the only places `didHoldSynthesis` was
    /// cleared, and a completed fast action reaches NEITHER: it retracts to
    /// silence, so `SpeechRouter.finish()` sees `didFeedSpeaker == false` and
    /// deliberately does not flush. The flag therefore survived into the NEXT
    /// turn on this shared speaker, where `holdSynthesis(for:)`'s "one hold per
    /// turn" guard turned that turn's hold away. Reproduced against this
    /// speaker with a control: after a retracted-to-silence turn, turn two's
    /// first batch went straight to synthesis, while the same turn two behind a
    /// turn one that flushed was correctly held.
    ///
    /// It costs nothing today, exactly as the hold itself costs nothing today —
    /// and it is the half of the guarantee the latency work will stand on, on
    /// the commonest sequence there is: "put on some jazz", then a question.
    ///
    /// `softStop()` still deliberately does NOT clear the flag: a retraction's
    /// replacement is mid-TURN, and holding the correction behind the same
    /// window it bought is the one delay this mechanism must never add.
    @discardableResult
    func endTurnUnspoken(lease: UUID? = nil) -> Bool {
        guard accepts(lease) else { return false }
        discardSynthesisHold()
        didHoldSynthesis = false
        return true
    }

    /// One chunk leaves for synthesis — or waits, if the hold is armed. The
    /// expiry is re-checked HERE as well as on the timer because a chunk that
    /// jumped a still-staged predecessor would reorder the reply.
    private func queueChunk(_ text: String) {
        guard !text.isEmpty else { return }
        if synthesisHoldExpiry != nil, !isSynthesisHeld {
            releaseSynthesisHold()
        }
        if isSynthesisHeld {
            heldChunks.append(text)
            return
        }
        ensurePipeline()
        emit(.chunkQueued(text))
        chunksQueuedThisPipeline += 1
        textContinuation?.yield(text)
    }

    /// Interrupt and reset. Also hard-stops any already-scheduled audio —
    /// the original processor's stop() left queued PCM playing.
    public func stop() {
        hardStop()
    }

    /// Provisional pause — the instant-response half of barge-in. The player
    /// node keeps its schedule and Stage A keeps synthesizing into the ring
    /// (backpressure caps it), so `resume()` continues mid-sentence with no
    /// loss. A committed barge-in calls `hardStop()` instead.
    public private(set) var isPaused = false

    public func pause() {
        guard isSpeaking, !isPaused else { return }
        if let player = activePlayer {
            player.pause()
        } else {
            guard dataPlayedBackDriverForTesting != nil else { return }
        }
        isPaused = true
        emit(.paused)
    }

    /// Lease-scoped provisional pause. A frame already dispatched by an old
    /// voice pipeline must not pause a later session after teardown releases
    /// and the later session claims this shared speaker.
    @discardableResult
    public func pause(lease: UUID) -> Bool {
        guard accepts(lease) else { return false }
        pause()
        return true
    }

    public func resume() {
        guard isPaused else {
            isPaused = false
            return
        }
        if let player = activePlayer {
            player.play()
        } else {
            guard dataPlayedBackDriverForTesting != nil else {
                isPaused = false
                return
            }
        }
        isPaused = false
        emit(.resumed)
    }

    /// Lease-scoped counterpart to `pause(lease:)`; stale barge-in retreat
    /// frames cannot resume a newer writer's paused player.
    @discardableResult
    public func resume(lease: UUID) -> Bool {
        guard accepts(lease) else { return false }
        resume()
        return true
    }

    /// Silence playback *now*: stop the live player/engine, cancel the pipeline,
    /// and reset all buffered text. This is what barge-in calls.
    public func hardStop() {
        invalidateAndHardStop()
    }

    /// Conditional reset for the current writer. If a newer user turn already
    /// owns the speaker, this is a no-op instead of letting an old event
    /// silence the newer reply. The accepting writer keeps its lease: a
    /// brain-side exchange supersede can discard prior audio yet continue
    /// streaming the replacement reply through the same router.
    @discardableResult
    public func hardStop(lease: UUID) -> Bool {
        guard accepts(lease) else { return false }
        hardResetEpoch &+= 1
        hardStopContents()
        return true
    }

    /// The destructive half of `hardStop()`.  A floor claim uses this after it
    /// has installed its new lease, so the new owner survives its own reset
    /// while every older lease is rejected.
    private func hardStopContents() {
        rawBuffer          = ""
        lastSeenString     = ""
        sentenceBatch      = ""
        sentenceBatchCount = 0
        discardSynthesisHold()
        didHoldSynthesis   = false
        textContinuation?.finish()
        textContinuation = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        synthTask?.cancel()
        synthTask = nil
        remoteContinuation?.finish()
        remoteContinuation = nil
        remoteTask?.cancel()
        remoteTask = nil
        let retiringPlayer = activePlayer
        let retiringEngine = activeEngine
        retiringPlayer?.stop()
        retiringEngine?.stop()
        activePlayer = nil
        activeEngine = nil
        Self.retireAudioGraph(engine: retiringEngine, player: retiringPlayer)
        isPaused = false
        resumeStopWaiters()
        if isSpeaking {
            isSpeaking = false
            emit(.stopped)
        }
    }

    // MARK: - Soft stop (sentence boundary)

    /// Sentence-boundary stop: accept no more text or synthesis, let the
    /// buffer currently audible finish, silence everything scheduled behind
    /// it, then tear down. Ends with the normal `.drained`; the caller's
    /// completion signal is this method returning. Falls back to hardStop()
    /// while paused (a paused buffer would never complete). Used when a
    /// routine's follow-up preempts the current reply.
    ///
    /// `handoff` is true only after a different writer has atomically claimed
    /// the floor. In an otherwise quiet gap it also invalidates a pending old
    /// synthesis tail; the default keeps same-turn retractions on their
    /// existing takeover-hold timeline.
    ///
    /// …AND IT IS THE PRIMITIVE THE TAKEOVER RIDES ON (`.retractSpeech`). It
    /// clears `rawBuffer`, `lastSeenString`, `sentenceBatch` and everything the
    /// hold staged, finishes the text continuation, and deliberately does NOT
    /// cancel the audio pipeline — so a sentence already audible drains to its
    /// own boundary instead of being cut mid-word, and nothing un-synthesized
    /// survives to speak later. It returns immediately when idle, which is the
    /// common case for a takeover: the acknowledgement it retracts is normally
    /// still text.
    @discardableResult
    public func softStop(lease: UUID? = nil, handoff: Bool = false) async -> Bool {
        guard accepts(lease) else { return false }
        let epoch = hardResetEpoch
        rawBuffer          = ""
        lastSeenString     = ""
        sentenceBatch      = ""
        sentenceBatchCount = 0
        discardSynthesisHold()
        textContinuation?.finish()
        textContinuation = nil
        synthTask?.cancel()
        synthTask = nil
        remoteContinuation?.finish()
        remoteContinuation = nil
        // Handles are dropped WITHOUT cancelling while audible playback
        // drains itself to the boundary. Keep local references so the silent
        // handoff path below can instead cancel work that has not become
        // audible yet.
        let pendingPipelineTask = pipelineTask
        let pendingRemoteTask = remoteTask
        pipelineTask = nil
        remoteTask = nil

        if isPaused {
            // Keep this caller's floor lease.  A retraction while paused is a
            // destructive stop of the *same* turn, not a new user boundary.
            hardStopContents()
            return accepts(lease) && epoch == hardResetEpoch
        }
        guard isSpeaking else {
            guard handoff else { return accepts(lease) && epoch == hardResetEpoch }
            // There is no audible buffer to preserve, so this is a true
            // cross-writer handoff rather than a same-turn retraction.
            // Invalidate any Stage A / not-yet-started Stage B tail as well:
            // simply finishing its input stream is not enough because a
            // cancelled synthesizer can return one old waveform after the
            // next writer has fed. Keep the current lease; only its prior
            // draft dies. A regular retraction deliberately does NOT take
            // this path: its replacement keeps the hold it already bought.
            hardResetEpoch &+= 1
            pendingPipelineTask?.cancel()
            pendingRemoteTask?.cancel()
            hardStopContents()
            return accepts(lease)
        }
        softStopRequested = true
        await withCheckedContinuation { stopWaiters.append($0) }
        guard accepts(lease), epoch == hardResetEpoch else { return false }
        softStopRequested = false
        return true
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters = []
        softStopRequested = false
        for waiter in waiters { waiter.resume() }
    }

    /// Buffer-completion hook: under a soft stop, the first `.dataPlayedBack`
    /// after the request marks "the audible buffer finished" — stop the
    /// player there, which fires the remaining scheduled buffers' handlers
    /// so the ring drains and `playWithRing` runs its normal epilogue.
    private func chunkPlayedBack(ring: RingBuffer, epoch: UInt64) async {
        guard epoch == hardResetEpoch else {
            await ring.release()
            return
        }
        if softStopRequested {
            activePlayer?.stop()
        }
        await ring.release()
        // `.dataPlayedBack` fires AFTER the audio was heard, so an empty ring
        // here means the room is genuinely silent — even though the turn is
        // still open. Consumers boosting a threshold against Mary's own
        // voice must hear about that gap: a turn held open across a Skill invocation
        // with a 3× boosted mic swallows the user at normal volume, and the
        // held reply then arrives late (the reported bug's front half).
        if epoch == hardResetEpoch, await ring.isIdle {
            emit(.audioIdle)
        }
    }

    // MARK: - Remote audio (server-synthesized PCM)

    /// A playback-only pipeline for pre-synthesized reply audio (the realtime
    /// Seer route): Stage A is skipped entirely and decoded waveforms feed
    /// `playWithRing` directly, so pause/resume/hardStop, ring backpressure,
    /// and `.started`/`.drained` events behave exactly like local synthesis.
    /// The ring only bounds buffers scheduled on the player node — excess PCM
    /// waits in the unbounded stream (~96 KB/s of speech) and never blocks
    /// the network reader.
    private var remoteContinuation: AsyncStream<(samples: [Float], rate: Double, text: String)>.Continuation?
    private var remoteTask: Task<Void, Never>?

    /// Arms the remote pipeline. Idempotent; a no-op while one is live.
    /// Callers drive text separately (transcript only) — never `feed(_:)`
    /// during a remote turn.
    @discardableResult
    public func beginRemoteAudio(lease: UUID? = nil) -> Bool {
        guard accepts(lease) else { return false }
        guard remoteContinuation == nil else { return true }
        let (stream, continuation) = AsyncStream<(samples: [Float], rate: Double, text: String)>
            .makeStream(bufferingPolicy: .unbounded)
        remoteContinuation = continuation
        let epoch = hardResetEpoch
        remoteTask = Task { [weak self] in
            await self?.playWithRing(stream, epoch: epoch)
        }
        return true
    }

    /// Enqueue one chunk of float32 little-endian mono PCM at `sampleRate`.
    /// Callers must pass 4-byte-aligned data (whole floats).
    @discardableResult
    public func enqueueRemotePCM(
        _ pcm: Data,
        sampleRate: Double,
        lease: UUID? = nil
    ) -> Bool {
        guard accepts(lease), beginRemoteAudio(lease: lease) else { return false }
        let samples = Self.decodeFloat32LE(pcm)
        guard !samples.isEmpty else { return true }
        remoteContinuation?.yield((samples, sampleRate, ""))
        return true
    }

    /// Raw little-endian float32 bytes → samples; trailing partial floats are
    /// dropped (transports carry their own alignment remainder).
    static func decodeFloat32LE(_ pcm: Data) -> [Float] {
        let count = pcm.count / MemoryLayout<Float32>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { destination in
            pcm.copyBytes(to: destination, count: count * MemoryLayout<Float32>.size)
        }
        return samples
    }

    /// Finish the remote stream and wait for scheduled audio to drain.
    @discardableResult
    public func endRemoteAudio(lease: UUID? = nil) async -> Bool {
        guard accepts(lease) else { return false }
        let epoch = hardResetEpoch
        remoteContinuation?.finish()
        remoteContinuation = nil
        let task = remoteTask
        remoteTask = nil
        await task?.value
        return accepts(lease) && epoch == hardResetEpoch
    }

    // MARK: - Sentence extraction

    /// Uses NLTokenizer to pull complete sentences out of `rawBuffer`.
    /// A sentence is only yielded when it ends *before* the buffer end —
    /// proving the tokenizer has seen the terminating punctuation and the
    /// start of the next sentence (or more whitespace), meaning it's truly done.
    private func extractSentences() {
        let ranges = Self.completeSentenceRanges(in: rawBuffer)
        guard let last = ranges.last else { return }

        for range in ranges {
            let raw = String(rawBuffer[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            // Sanitize markdown before handing off to synthesis
            let clean = sanitize(raw)
            guard !clean.isEmpty else { continue }

            // GROWTH AFTER THE FIRST CHUNK. Chunk 0 keeps the ctor limits
            // (fast first audio; the takeover arithmetic is pinned to them);
            // later chunks of a cloud pipeline batch more sentences, so a
            // long passage has fewer seams and one prosody arc per batch.
            let growing = chunksQueuedThisPipeline > 0 ? chunkPolicy : nil
            let effectiveMaxWords = growing?.laterMaxWords ?? maxWordsPerChunk
            let effectiveSentences = growing?.laterSentencesPerChunk ?? sentencesPerChunk

            // If adding this sentence would overflow the word budget, flush first
            let incomingWords = clean.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
            let currentWords  = sentenceBatch.isEmpty ? 0 :
                sentenceBatch.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
            if !sentenceBatch.isEmpty && currentWords + incomingWords > effectiveMaxWords {
                queueChunk(sentenceBatch)
                sentenceBatch = ""
                sentenceBatchCount = 0
            }

            // Accumulate into batch
            sentenceBatch = sentenceBatch.isEmpty ? clean : sentenceBatch + " " + clean
            sentenceBatchCount += 1

            // Flush once we have enough sentences
            if sentenceBatchCount >= effectiveSentences {
                queueChunk(sentenceBatch)
                sentenceBatch = ""
                sentenceBatchCount = 0
            }
        }

        rawBuffer = String(rawBuffer[last.upperBound...])
            .trimmingCharacters(in: .init(charactersIn: " \t"))
    }

    /// WHICH PARTS OF `text` ARE COMPLETE SENTENCES, by this speaker's single
    /// rule: a sentence counts only when it ends STRICTLY BEFORE the end of the
    /// buffer, which is what proves the tokenizer saw both its terminator and
    /// the start of whatever follows it.
    ///
    /// Factored out of `extractSentences` so `mayAlreadyBeAudible` can ask the
    /// same question the chunker answers, rather than a second approximation of
    /// it living in another package. Two copies of "has this text produced
    /// audio yet?" is precisely how one of them comes to be wrong.
    static func completeSentenceRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            guard range.upperBound < text.endIndex else { return false }
            ranges.append(range)
            return true
        }
        return ranges
    }

    /// COULD THIS TEXT ALREADY HAVE REACHED SYNTHESIS? The bound the takeover
    /// rests on, asked of the chunker instead of guessed at by its callers.
    ///
    /// True once `defaultSentencesPerChunk` complete sentences are in — which
    /// takes `sentencesBeforeFirstAudio` sentences of text, the last one only
    /// there to prove the one before it ended. Below that threshold a
    /// retraction is TOTAL: nothing has been handed to a synthesizer and
    /// nothing can be heard. At or above it the voice lane wrote a real answer
    /// the user is already listening to, and cutting it off mid-reply is worse
    /// than the stale sentence the takeover exists to remove.
    ///
    /// Answers for the SHIPPED configuration (`MaryRuntime.speaker` and both
    /// probes take the defaults); a speaker built with a custom
    /// `sentencesPerChunk` is a test fixture, and the brain has no handle on
    /// the speaker to ask anyway.
    public static func mayAlreadyBeAudible(_ text: String) -> Bool {
        completeSentenceRanges(in: text).count >= defaultSentencesPerChunk
    }

    // MARK: - Markdown sanitization

    /// Strips common markdown formatting so the TTS model receives clean prose.
    private func sanitize(_ text: String) -> String {
        var s = text

        // Fenced code blocks — drop content entirely (not speakable)
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#,       with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`[^`]+`"#,              with: " ", options: .regularExpression)

        // Images — drop entirely
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: " ", options: .regularExpression)

        // Links — keep display text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)

        // Bold / italic / strikethrough — paired delimiters (longest match first)
        s = s.replacingOccurrences(of: #"\*\*\*(.+?)\*\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"___(.+?)___"#,        with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#,      with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"__(.+?)__"#,          with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*(.+?)\*"#,          with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"_(.+?)_"#,            with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~(.+?)~~"#,          with: "$1", options: .regularExpression)

        // Strip unmatched/dangling delimiters — e.g. opening ** whose closing ** is in
        // a different sentence after NLTokenizer splits the buffer mid-bold span.
        s = s.replacingOccurrences(of: #"\*+"#,  with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~"#,   with: "")
        s = s.replacingOccurrences(of: #"__"#,   with: "")

        // ATX headers (# Title) — keep the title text
        s = s.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)

        // Horizontal rules
        s = s.replacingOccurrences(of: #"(?m)^[-*_]{3,}\s*$"#, with: "", options: .regularExpression)

        // Block-quote markers
        s = s.replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)

        // Unordered list markers (-, *, +)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)

        // Ordered list markers (1. 2. etc.)
        s = s.replacingOccurrences(of: #"(?m)^\s*\d+\.\s+"#, with: "", options: .regularExpression)

        // Collapse multiple blank lines / excessive whitespace
        s = s.replacingOccurrences(of: #"\n{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+"#,  with: " ", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pipeline

    /// The pipeline is created lazily at the moment TEXT ACTUALLY LEAVES for
    /// synthesis — the first queued chunk, or a flush with something in it —
    /// and after each completed or stopped stream, so a fresh turn always gets
    /// a fresh stream.
    ///
    /// IT USED TO BE CREATED ON THE FIRST `feed`, AND THAT WAS A PHANTOM.
    /// `playWithRing` starts the AVAudioEngine and emits `.started` BEFORE it
    /// awaits a single waveform, so one token was enough to flash the UI's
    /// "speaking" state on a turn that never spoke — the same phantom
    /// `SpeechRouter.finish()`'s `didFeedSpeaker` guard was written to stop for
    /// zero-token turns, arriving by the one road that guard cannot see. It is
    /// exactly the road a takeover-to-silence takes: Lane A's acknowledgement
    /// is fed, then retracted, and nothing is ever synthesized. Creating the
    /// pipeline where the text leaves costs no first-audio latency (Stage A's
    /// network round trip dwarfs `AVAudioEngine.start()`, and the two begin
    /// together) and makes "speaks nothing" mean it.
    private func ensurePipeline() {
        guard pipelineTask == nil else { return }
        chunksQueuedThisPipeline = 0
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        textContinuation = continuation
        let epoch = hardResetEpoch
        pipelineTask = Task { [weak self] in
            await self?.runPipeline(stream, epoch: epoch)
        }
    }

    private func runPipeline(_ textStream: AsyncStream<String>, epoch: UInt64) async {
        guard epoch == hardResetEpoch else { return }
        // Carry (samples, rate, text) so each chunk can have a different rate —
        // necessary when short chunks use a 21 kHz variant and longer ones 24 kHz.
        let (waveformStream, waveformCont) = AsyncStream<(samples: [Float], rate: Double, text: String)>
            .makeStream(bufferingPolicy: .unbounded)

        // Stage A — synthesis, runs concurrently with Stage B, WITH LOOKAHEAD.
        //
        // It used to synthesize strictly one chunk at a time, so any slow
        // chunk — a network retry, a token refresh — ran the player dry and
        // the passage stalled mid-paragraph, then lurched on. Up to
        // `prefetchDepth` chunks are now in flight; a reorder buffer yields
        // them strictly in order, so playback order is untouchable and the
        // ring's own depth still bounds how far audio runs ahead.
        //
        // A chunk that throws PAST every engine retry and fallback is emitted
        // as `.chunkFailed` instead of vanishing silently — the sentence is
        // skipped, the reply continues, and the host can say why.
        //
        // Cancellation: the task group's children are children of this
        // detached task, which `hardStopContents`/`softStop` cancel exactly
        // as before — in-flight cloud requests observe it through the same
        // structured path.
        let synthesizer = self.synthesizer
        let synthStage = Task.detached(priority: .userInitiated) { [weak self] in
            // ONE PIPELINE == ONE UTTERANCE. The engine resets per-utterance
            // state (pinned emotion, pinned gain) here, so a whole reply
            // renders in one voice and a proactive follow-up — its own
            // pipeline — classifies afresh.
            await synthesizer.beginUtterance()

            enum Landed {
                case chunk(SynthesizedChunk)
                case failed(reason: String)
            }
            await withTaskGroup(of: (Int, Landed, String).self) { group in
                var nextIndex = 0
                var nextToYield = 0
                var inFlight = 0
                var ready: [Int: (Landed, String)] = [:]

                func drain() async {
                    while let (landed, text) = ready.removeValue(forKey: nextToYield) {
                        nextToYield += 1
                        switch landed {
                        case .chunk(let chunk):
                            if let report = chunk.pronunciation {
                                await self?.emitPronunciation(report, epoch: epoch)
                            }
                            waveformCont.yield((chunk.samples, chunk.sampleRate, text))
                        case .failed(let reason):
                            await self?.emitChunkFailed(
                                text: text, reason: reason, epoch: epoch)
                        }
                    }
                }

                for await text in textStream {
                    if Task.isCancelled { break }
                    if inFlight >= Self.prefetchDepth, let landed = await group.next() {
                        inFlight -= 1
                        ready[landed.0] = (landed.1, landed.2)
                        await drain()
                    }
                    let index = nextIndex
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        do {
                            let chunk = try await synthesizer.synthesizeChunk(text)
                            return (index, .chunk(chunk), text)
                        } catch {
                            return (index, .failed(reason: error.localizedDescription), text)
                        }
                    }
                }
                for await landed in group {
                    ready[landed.0] = (landed.1, landed.2)
                    await drain()
                }
            }
            waveformCont.finish()
        }
        synthTask = synthStage

        // Stage B — ring-buffered playback
        await playWithRing(waveformStream, epoch: epoch)
        await synthStage.value
    }

    // MARK: - Ring-buffered playback

    private func playWithRing(
        _ waveformStream: AsyncStream<(samples: [Float], rate: Double, text: String)>,
        epoch: UInt64
    ) async {
        guard epoch == hardResetEpoch else { return }
        if let driver = dataPlayedBackDriverForTesting {
            await playWithTestingDriver(waveformStream, epoch: epoch, driver: driver)
            return
        }
        let hwRate = KokoroEngine.hardwareSampleRate()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard hwRate.isFinite, hwRate > 0,
              let fmt = AVAudioFormat(
                standardFormatWithSampleRate: hwRate, channels: 1)
        else {
            // A route can briefly report 0 Hz while Bluetooth/CoreAudio is
            // reconfiguring. Treat it as unavailable output, and quarantine
            // this graph just like every other early playback failure.
            player.stop()
            engine.stop()
            Self.retireAudioGraph(engine: engine, player: player)
            return
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        do {
            try engine.start()
        } catch {
            player.stop()
            engine.stop()
            Self.retireAudioGraph(engine: engine, player: player)
            return
        }
        player.play()

        // Retain so hardStop() can silence scheduled audio immediately.
        activeEngine = engine
        activePlayer = player

        let ring = RingBuffer(capacity: ringDepth)
        var didStartPlayback = false

        for await (waveform, modelRate, text) in waveformStream {
            if Task.isCancelled || softStopRequested || epoch != hardResetEpoch { break }
            let samples: [Float]
            if modelRate != hwRate,
               let resampled = try? KokoroEngine.resample(waveform, from: modelRate, to: hwRate) {
                samples = resampled
            } else {
                samples = waveform
            }
            guard !samples.isEmpty else { continue }
            guard let buf = makePCMBuffer(samples, rate: hwRate) else { continue }

            await ring.acquire()
            if Task.isCancelled || softStopRequested || epoch != hardResetEpoch {
                await ring.release()
                break
            }

            if !didStartPlayback {
                didStartPlayback = true
                isSpeaking = true
                emit(.started)
            }
            emit(.chunkScheduled(text))
            player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task {
                    if let self {
                        await self.chunkPlayedBack(ring: ring, epoch: epoch)
                    } else {
                        await ring.release()
                    }
                }
            }
        }

        await ring.drain()
        guard epoch == hardResetEpoch else { return }
        // hardStop() may already have silenced and cleared the nodes.
        if activePlayer === player {
            player.stop()
            engine.stop()
            activePlayer = nil
            activeEngine = nil
            Self.retireAudioGraph(engine: engine, player: player)
        }
        resumeStopWaiters()
        if isSpeaking {
            isSpeaking = false
            emit(.drained)
        }
        // pipelineTask/textContinuation are managed by flush()/hardStop() —
        // clearing them here would race a fresh pipeline started mid-drain.
    }

    private static func retireAudioGraph(
        engine: AVAudioEngine?,
        player: AVAudioPlayerNode?
    ) {
        guard engine != nil || player != nil else { return }
        let graph = RetiredOutputAudioGraph(engine: engine, player: player)
        audioRetirementQueue.asyncAfter(
            deadline: .now() + audioRetirementGrace
        ) {
            graph.keepAlive()
        }
    }

    /// Mirrors the production player's lifecycle for deterministic tests. A
    /// driver's return is the test transport's `.dataPlayedBack` callback —
    /// therefore `.drained` and `flush()` cannot occur before it returns.
    private func playWithTestingDriver(
        _ waveformStream: AsyncStream<(samples: [Float], rate: Double, text: String)>,
        epoch: UInt64,
        driver: DataPlayedBackDriver
    ) async {
        var didStartPlayback = false
        for await (samples, rate, text) in waveformStream {
            if Task.isCancelled || softStopRequested || epoch != hardResetEpoch { break }
            guard !samples.isEmpty else { continue }
            if !didStartPlayback {
                didStartPlayback = true
                isSpeaking = true
                emit(.started)
            }
            emit(.chunkScheduled(text))
            await driver(samples, rate, text)
            if Task.isCancelled || softStopRequested || epoch != hardResetEpoch { break }
            // The driver returning is exactly the data-played-back boundary.
            emit(.audioIdle)
        }

        guard epoch == hardResetEpoch else { return }
        resumeStopWaiters()
        if isSpeaking {
            isSpeaking = false
            emit(.drained)
        }
    }

    // MARK: - Audio helpers

    private func makePCMBuffer(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer? {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch  = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        return buf
    }
}

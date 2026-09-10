//
//  KokoroStreamSpeaker.swift
//  MaryVoice
//
//  WHAT: Streaming LLM text → Kokoro TTS via a circular PCM buffer.
//  IN:   SpeechRouter / VoicePipeline / probes
//  OUT:  SpeakerEvent tap; playback via RingBuffer
//
//    feed() → rawBuffer → [sentences + markdown sanitize] → textStream
//    Stage A: textStream → synthesizer.synthesizeWaveform() → waveformStream
//    Stage B: waveformStream → ring.acquire() → scheduleBuffer() → ring.release()
//
//  PIN: Injectable actor. hardStop silences scheduled PCM (barge-in). Floor
//       lease checked inside this actor.
//

import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - RingBuffer

// MARK: - KokoroStreamSpeaker

/// Chunking: NLTokenizer(.sentence) takes fully-terminated sentences; trailing
/// incomplete stays buffered. Hard word cap splits over-long sentences.
public actor KokoroStreamSpeaker {

    /// Floor lease checked inside this actor at the mutation point. Callers mint
    /// the UUID; a fresh claim revokes older ids. Unleased calls only while idle.
    // MARK: - Public

    public private(set) var isSpeaking = false

    public var style: TTSSpeechStyle

    /// Pre-queued PCM buffer slots. 3 = playing + queued + synthesising.
    public let ringDepth: Int

    /// Number of complete sentences to accumulate before yielding a synthesis chunk.
    /// 2–3 feels natural; lower = more responsive but choppier gaps between chunks.
    public let sentencesPerChunk: Int

    /// Shipped chunk size — named so takeover arithmetic can reason about it.
    public static let defaultSentencesPerChunk = 2

    /// Sentences of text before first audio can exist: defaultSentencesPerChunk
    /// complete + 1 to prove the last ended. PIN: takeover window arithmetic.
    public static let sentencesBeforeFirstAudio = defaultSentencesPerChunk + 1

    /// Hard word-count ceiling per chunk. Kokoro 10s ≈ 242 tokens ≈ 40 words; 30 is headroom.
    public let maxWordsPerChunk: Int

    // MARK: - Private

    /// Swappable via `setSynthesizer`; a change applies to the next pipeline
    /// run — a turn already speaking finishes on the backend it started with.
    private var synthesizer: any SpeechSynthesizer

    /// Raw accumulated text, possibly containing markdown and partial sentences.
    private var rawBuffer: String = ""
    private var lastSeenString: String = ""

    /// The only writer allowed to mutate. nil = probes/tests (unleased).
    private var activeFloorLease: UUID?
    /// Voice session owns the floor between utterances too.
    private var voiceFloorReserved = false
    /// Invalidates async tails. A cancelled old flush must not reset the next turn.
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

    /// Keep a stopped output graph alive through CoreAudio I/O-unit retirement.
    private static let audioRetirementQueue = DispatchQueue(
        label: "mary.speaker.engine-retirement")
    private static let audioRetirementGrace: TimeInterval = 10

    /// Test playback seam — awaited where production waits for `.dataPlayedBack`. Nil in production.
    typealias DataPlayedBackDriver = @Sendable (
        _ samples: [Float], _ sampleRate: Double, _ text: String
    ) async -> Void
    private var dataPlayedBackDriverForTesting: DataPlayedBackDriver?

    /// Sentence-boundary stop: first buffer completion stops the player. See softStop().
    private var softStopRequested = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// Chunks that reached a batch boundary while the hold was armed. See holdSynthesis().
    private var synthesisHoldExpiry: DispatchTime?
    private var heldChunks: [String] = []
    private var holdReleaseTask: Task<Void, Never>?
    /// One hold per turn. Cleared by flush/hardStop, not by softStop (turn continues).
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

    /// Claim for a text-mode writer. Refused while a voice session owns the floor.
    @discardableResult
    public func claimTextFloor(_ lease: UUID, hardStop: Bool = true) -> Bool {
        guard !voiceFloorReserved else { return false }
        claimFloor(lease, hardStop: hardStop)
        return true
    }

    /// CAS handoff from a known writer. Idle speaker is a valid target (primary released after drain).
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

    /// Claim for the live voice pipeline, including between utterances.
    @discardableResult
    public func claimVoiceFloor(_ lease: UUID, hardStop: Bool = true) -> Bool {
        voiceFloorReserved = true
        claimFloor(lease, hardStop: hardStop)
        return true
    }

    /// CAS handoff inside a voice session. Idle is NOT a valid target (barge-in / shutdown).
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

    /// Release voice mode when the mic session ends. Stale voice tasks must not resume.
    public func leaveVoiceFloor() {
        voiceFloorReserved = false
        invalidateAndHardStop()
    }

    /// Conditional release for a failed session start. Must not release a newer claim.
    @discardableResult
    public func leaveVoiceFloor(lease: UUID) -> Bool {
        guard voiceFloorReserved, activeFloorLease == lease else { return false }
        voiceFloorReserved = false
        invalidateAndHardStop()
        return true
    }

    /// Cheap preflight. Every mutating API re-checks the lease inside this actor.
    public func ownsFloor(_ lease: UUID) -> Bool {
        accepts(lease)
    }

    /// Release a completed writer without interrupting drained audio.
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

    /// Stage A in-flight cap. Two: one slow chunk never runs the player dry.
    static let prefetchDepth = 2

    private func emitChunkFailed(text: String, reason: String, epoch: UInt64) {
        guard epoch == hardResetEpoch else { return }
        // A cancelled chunk is the pipeline being torn down, not a lost
        // sentence — barge-in must not read as a failure.
        guard !reason.localizedCaseInsensitiveContains("cancel") else { return }
        emit(.chunkFailed(text: text, reason: reason))
    }

    // MARK: - Public API

    /// Feed the full accumulated LLM string. Diffs internally; only the new suffix appends.
    /// PIN: a string that does not extend lastSeenString is a foreign writer — reset baseline, speak nothing.
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

    /// Flush remaining text and wait for queued audio. Re-check the lease after the await.
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

    /// Skill-lane join grace (250 ms). Matches MaryBrain non-action join. TakeoverTests pins both.
    public static let takeoverHoldNanoseconds: UInt64 = 250_000_000

    /// Hold synthesis for the takeover window. Armed by SpeechRouter on first local token.
    /// Batching continues; only the handoff waits. Retraction discards staged chunks.
    @discardableResult
    func holdSynthesis(for nanoseconds: UInt64, lease: UUID? = nil) -> Bool {
        // Existing hold on this turn is a successful no-op (replacement keeps the window).
        guard accepts(lease) else { return false }
        guard !didHoldSynthesis else { return true }
        didHoldSynthesis = true
        synthesisHoldExpiry = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
        let epoch = hardResetEpoch
        // Self-releasing: a quiet stream inside the window must not leave staged audio.
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

    /// Drop the hold and everything it staged. Retraction paths only.
    private func discardSynthesisHold() {
        holdReleaseTask?.cancel()
        holdReleaseTask = nil
        synthesisHoldExpiry = nil
        heldChunks = []
    }

    /// Silent turn still ended — clear didHoldSynthesis so the next turn can hold.
    /// PIN: softStop does not clear (replacement is mid-turn).
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

    /// Provisional barge-in pause. Schedule + Stage A keep running; `resume()` continues. Committed barge-in is `hardStop()`.
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

    /// Reset for this writer only. No-op if a newer turn owns the floor.
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

    /// Sentence-boundary stop. Primitive for `.retractSpeech`. `handoff` after
    /// a different writer claimed the floor. Falls back to hardStop while paused.
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
        // Drop handles without cancelling while audible playback drains. Local refs for the silent-handoff path.
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
            // Cross-writer handoff (nothing audible). Cancel Stage A/B tails; keep this lease.
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

    /// Soft-stop: first `.dataPlayedBack` after the request stops the player so the ring drains.
    private func chunkPlayedBack(ring: RingBuffer, epoch: UInt64) async {
        guard epoch == hardResetEpoch else {
            await ring.release()
            return
        }
        if softStopRequested {
            activePlayer?.stop()
        }
        await ring.release()
        // Empty ring after playback = room is silent. Consumer: barge-in threshold (not Mary's own voice).
        if epoch == hardResetEpoch, await ring.isIdle {
            emit(.audioIdle)
        }
    }

    // MARK: - Remote audio (server-synthesized PCM)

    /// Playback-only pipeline (server PCM). Same ring / pause / events as local; Stage A skipped.
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

    /// Complete sentences in `rawBuffer` — only those that end before the buffer end.
    private func extractSentences() {
        let ranges = Self.completeSentenceRanges(in: rawBuffer)
        guard let last = ranges.last else { return }

        for range in ranges {
            let raw = String(rawBuffer[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            // Sanitize markdown before handing off to synthesis
            let clean = sanitize(raw)
            guard !clean.isEmpty else { continue }

            // Chunk 0 keeps ctor limits (fast start / takeover math); later chunks may grow.
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

    /// Sentence ranges that end strictly before `text.endIndex`. Shared with `mayAlreadyBeAudible`.
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

    /// True once defaultSentencesPerChunk complete sentences are in (shipped config).
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

    /// Create the pipeline when text actually leaves for synthesis — not on first feed.
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

        // Stage A: synthesize with lookahead; reorder buffer yields in order. Throws → `.chunkFailed`.
        let synthesizer = self.synthesizer
        let synthStage = Task.detached(priority: .userInitiated) { [weak self] in
            // One pipeline = one utterance. Engine resets pinned emotion/gain here.
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

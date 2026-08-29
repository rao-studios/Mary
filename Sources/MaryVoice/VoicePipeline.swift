//
//  VoicePipeline.swift
//  MaryVoice
//
//  The conversational auto-loop:
//
//    idle ─start()→ listening(waiting) ─VAD speechStart→ listening(active)
//      ─VAD endpoint→ transcribing ─final transcript→ thinking
//      ─first TTS audio→ speaking ─reply done + drained→ listening(waiting)
//    speaking ─sustained user speech→ barge-in → listening(active)
//
//  The mic tap never closes mid-session: while Mary speaks it watches for
//  barge-in (with a boosted threshold so she ignores her own voice), and a
//  ~300 ms pre-roll ring is replayed into the transcriber so first syllables
//  never clip. Every stage multicasts VoicePipelineEvents to any number of
//  subscribers — the app's UI, the probe CLI, tests.
//
//  This actor is the orchestrator: it sequences calls to four collaborators
//  that each own one slice of state —
//    - VoiceFloorOwner: who owns the shared speaker's voice floor right now.
//    - AmendCapture: the thinking-phase-interrupt correction buffer.
//    - ProactiveDeliveryState: what proactive speech is buffered, and whose.
//    - FollowUpPriority: the pure decision over what a follow-up token does.
//  Turn/session/frame orchestration itself is split by MARK region across
//  VoicePipeline+*.swift files in this same directory — same actor, same
//  isolation domain, no behavior change from the split itself.
//

import AVFoundation
import Foundation

public actor VoicePipeline {

    let config: VoicePipelineConfig
    let transcriber: any VoiceTranscriber
    let speaker: KokoroStreamSpeaker
    let responder: any LanguageResponder

    let voiceFloor: VoiceFloorOwner
    var amendCapture: AmendCapture
    var proactive = ProactiveDeliveryState()

    /// A pipeline is single-use. Once teardown starts, no continuation that
    /// was already suspended in a collaborator may reopen the microphone,
    /// reclaim the shared speaker, or cancel a later session's responder.
    private(set) var terminated = false
    private var terminationComplete = false
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    public private(set) var state: VoicePipelineState = .idle

    var mic: MicCapture?
    var micLoopTask: Task<Void, Never>?
    var turnTask: Task<Void, Never>?
    var partialTask: Task<Void, Never>?

    let vad: EnergyVAD
    /// (buffer, duration) ring holding the last ~preRollMs of audio.
    var preRoll: [(AVAudioPCMBuffer, TimeInterval)] = []
    var preRollDuration: TimeInterval = 0
    /// Sustained voiced time while speaking — the barge-in trigger.
    var bargeGovernor: BargeInGovernor?
    /// True only while audio is ACTUALLY audible. `.speaking` is a turn-level
    /// state that outlives the sound: a turn held open across a Skill call, a
    /// slow lane, or a second model pass sits in `.speaking` with a silent
    /// speaker. The `bargeInRMSBoost` exists so the mic ignores Mary's OWN
    /// voice — with no voice playing it only deafens her to the user, who
    /// then speaks at normal volume, is swallowed, and hears the held reply
    /// arrive late (traced from a live session).
    var speakerAudioLive = false
    var levelFrameCounter = 0

    /// Whether responder.respond was actually called for the current turn.
    var respondStarted = false
    /// The exchange currently on screen — every `.turnBegan`. The reference
    /// point a follow-up's origin is judged against.
    var currentUserTurnID: UUID?
    /// True only while the responder's event loop is live — `.speaking` alone
    /// can't distinguish mid-generation from post-generation drain, and the
    /// follow-up preemption semantics differ (cancel the turn vs. cut audio).
    var generationActive = false

    private var eventContinuations: [UUID: AsyncStream<VoicePipelineEvent>.Continuation] = [:]

    /// CONTINUOUS HEARING IS OPTIONAL AND ADDITIVE. Nil is the shipping
    /// default and the whole acoustic path behaves exactly as it always has;
    /// supplying one adds a session-long transcript beside it that can only
    /// REMEMBER or OFFER, never take.
    let continuous: (any ContinuousTranscribing)?
    let intakeTuning: IntakePlanner.Tuning
    /// Finalized spans accumulated since the last decision.
    var heardBuffer = ""
    /// Fires once the room has been quiet for `completionSilence`. Cancelled
    /// and rescheduled by each new span, which is what lets a pause mid-thought
    /// extend the utterance instead of cutting it in half — the exact failure
    /// the flat 850 ms hangover causes.
    var heardDecisionTask: Task<Void, Never>?
    var continuousTask: Task<Void, Never>?

    var proactiveTask: Task<Void, Never>?

    /// The last query submitted (or about to be) — the amend flow's
    /// "original" when the user supersedes it.
    var lastFinalTranscript = ""

    /// True while the goodbye is in flight. `handleProactive` refuses under
    /// it: `proactiveTask` is cancelled below, but one already-dispatched
    /// event can still land mid-drain, and a follow-up stealing the ack's
    /// lease would clip the goodbye and blurt a fragment of old work.
    var stopExitInProgress = false
    /// Identity of the acknowledgement currently ending this session. Actor
    /// reentrancy matters here: `speaker.flush` may be suspended in Seer or in
    /// real audio playback while an external stop tears the session down.
    /// Identity prevents that stale continuation from emitting a second stop.
    var stopExitID: UUID?

    public init(
        config: VoicePipelineConfig,
        transcriber: any VoiceTranscriber,
        speaker: KokoroStreamSpeaker,
        responder: any LanguageResponder,
        continuous: (any ContinuousTranscribing)? = nil,
        intakeTuning: IntakePlanner.Tuning = .standard
    ) {
        self.config = config
        self.transcriber = transcriber
        self.speaker = speaker
        self.responder = responder
        self.continuous = continuous
        self.intakeTuning = intakeTuning
        self.vad = EnergyVAD(config: config.vad)
        self.voiceFloor = VoiceFloorOwner(speaker: speaker, responder: responder)
        self.amendCapture = AmendCapture(vadConfig: config.vad)
    }

    // MARK: - Events

    /// A fresh stream of pipeline events for each subscriber. Streams end when
    /// the session stops.
    public func events() -> AsyncStream<VoicePipelineEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<VoicePipelineEvent>.makeStream(bufferingPolicy: .unbounded)
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

    func emit(_ event: VoicePipelineEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Test seams (preemption tests drive handleProactive directly;
    // a real session needs a mic and a human)

    func setStateForTesting(_ newState: VoicePipelineState) async {
        state = newState
        // Production reserves the voice floor in `start()`. The direct
        // proactive-playback seams model a live session without opening a
        // microphone, so give them the same reservation rather than letting
        // tests bypass the ownership protocol.
        if newState != .idle, voiceFloor.currentLease == nil {
            _ = await voiceFloor.claim()
        }
    }
    func setGenerationActiveForTesting(_ flag: Bool) { generationActive = flag }
    func setCurrentUserTurnIDForTesting(_ id: UUID?) { currentUserTurnID = id }
    func handleSpeakerEventForTesting(_ event: SpeakerEvent) { handleSpeakerEvent(event) }
    var isFollowUpSpeaking: Bool { proactive.followUpSpeaking }
    var followUpBufferForTesting: String { proactive.followUpBuffer }
    var bargeInOnsetForTesting: Float { bargeInOnsetRMS }
    func submitTurnForTesting(_ query: String) async {
        await submitTurn(query: query, superseding: false)
    }
    func runTurnForTesting() async {
        await runTurn()
    }
    func handleFrameForTesting(_ frame: MicFrame) async {
        await handle(frame: frame)
    }

    func transition(to newState: VoicePipelineState) {
        guard state != newState else { return }
        state = newState
        emit(.stateChanged(newState))
    }

    // MARK: - Session control

    public func start() async throws {
        guard !terminated else { throw CancellationError() }
        guard state == .idle else { return }
        // Reserve the floor before opening the mic. A text-mode follow-up
        // that was holding for quiet must not use the listening gap as a
        // chance to speak over a just-started voice session.
        guard let startLease = await voiceFloor.claim() else { throw CancellationError() }
        let mic = MicCapture(voiceProcessing: config.vad.voiceProcessing)
        let frames: AsyncStream<MicFrame>
        do {
            frames = try mic.start()
        } catch {
            await voiceFloor.abandon(startLease)
            throw error
        }
        self.mic = mic
        vad.reset()
        preRoll = []
        preRollDuration = 0
        transition(to: .listening(utteranceActive: false))
        // No format means no tap installed, so there is nothing to hear —
        // the acoustic path will fail on its own terms and say so.
        if let format = mic.format { await startContinuousHearing(format: format) }
        guard !terminated, state != .idle else {
            mic.stop()
            throw CancellationError()
        }

        // ROUTE: MicLoop task that runs turns
        micLoopTask = Task {
            for await frame in frames {
                if Task.isCancelled { break }
                await self.handle(frame: frame)
            }
        }

        // Detached routines speak their grounded follow-ups through the same
        // speaker — when the room is quiet.
        proactiveTask = Task {
            for await event in responder.proactiveEvents() {
                if Task.isCancelled { break }
                await self.handleProactive(event)
            }
        }
    }

    public func stop() async {
        if terminated {
            guard !terminationComplete else { return }
            await withCheckedContinuation { continuation in
                terminationWaiters.append(continuation)
            }
            return
        }
        terminated = true
        voiceFloor.markTerminated()

        // Close the logical session before any cancellation hop. A cancelled
        // proactive stream may deliver one last event; idle state makes that
        // event inert instead of letting it rebuild follow-up state while the
        // microphone is shutting down.
        transition(to: .idle)
        // Invalidate an acknowledgement suspended in synthesis/playback. If
        // an external stop wins that race, its hard speaker stop is the end of
        // the session; the old acknowledgement must not later emit a second
        // stop command when its flush unwinds.
        stopExitID = nil
        stopExitInProgress = false
        micLoopTask?.cancel()
        micLoopTask = nil
        proactiveTask?.cancel()
        proactiveTask = nil
        heardDecisionTask?.cancel()
        heardDecisionTask = nil
        continuousTask?.cancel()
        continuousTask = nil
        heardBuffer = ""
        turnTask?.cancel()
        turnTask = nil
        partialTask?.cancel()
        partialTask = nil
        voiceFloor.stopWatch()

        // Physical ownership is released before the first collaborator await.
        // `continuous.endSession()` may bridge an analyzer that is slow or
        // wedged; an explicit UI/error stop must never leave the CoreAudio tap
        // alive behind it. The spoken-command path reaches this method only
        // after its acknowledgement has already drained and stopped the mic.
        mic?.stop()
        mic = nil
        proactive.forceStop()
        // A stale marker across sessions would make the NEXT session's first
        // barge-in look like it interrupted a remark that ended long ago.
        proactive.ambientCandidateID = nil
        currentUserTurnID = nil
        speakerAudioLive = false
        amendCapture.reset()
        respondStarted = false
        generationActive = false

        // These collaborators belong only to this pipeline. They may bridge
        // Speech frameworks that never return from shutdown, so start both
        // cleanups independently and do not let either hold the shared session
        // box. They retain themselves until their own cleanup finishes.
        let retiringTranscriber = transcriber
        Task.detached(priority: .utility) {
            await retiringTranscriber.cancel()
        }
        if let retiringContinuous = continuous {
            Task.detached(priority: .utility) {
                await retiringContinuous.endSession()
            }
        }

        // A claim/handoff already dispatched to the shared speaker must settle
        // before the unconditional session-floor release. Once this returns,
        // all old TTS work is lease-revoked and its output graph is retired.
        await voiceFloor.waitForOwnershipOperations()
        await voiceFloor.releaseUnconditionally()

        // Responder cancellation is shared with text mode and the next voice
        // session, so it remains inside the ownership fence. Drain any older
        // cancellation first, then make this stop's cancellation the final one
        // before exposing the box as free.
        await voiceFloor.waitForResponderCancellations()
        await voiceFloor.cancelResponder()
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations = [:]

        terminationComplete = true
        let waiters = terminationWaiters
        terminationWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Manual interrupt (UI button / hotkey) — same path as acoustic barge-in.
    public func bargeIn() async {
        guard state == .speaking || state == .thinking || state == .transcribing else { return }
        await performBargeIn()
    }
}

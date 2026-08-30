//
//  VoicePipeline.swift
//  MaryVoice
//
//  WHAT: Conversational auto-loop. Orchestrates four collaborators.
//  IN:   MicCapture / EnergyVAD / VoiceTranscriber / LanguageResponder / KokoroStreamSpeaker
//  OUT:  VoicePipelineEvent (UI / probes / tests)
//        VoiceFloorOwner / AmendCapture / ProactiveDeliveryState / FollowUpPriority
//        VoicePipeline+*.swift (same actor)
//
//    idle ─start()→ listening(waiting) ─VAD speechStart→ listening(active)
//      ─VAD endpoint→ transcribing ─final transcript→ thinking
//      ─first TTS audio→ speaking ─reply done + drained→ listening(waiting)
//    speaking ─sustained user speech→ barge-in → listening(active)
//
//  PIN: Mic stays open for barge-in. ~300 ms pre-roll into the transcriber.
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

    /// Single-use. After teardown starts, no suspended continuation may reopen
    /// the mic, reclaim the speaker, or cancel a later session's responder.
    private(set) var terminated = false
    private var terminationComplete = false
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    public private(set) var state: VoicePipelineState = .idle

    var mic: MicCapture?
    var micLoopTask: Task<Void, Never>?
    var turnTask: Task<Void, Never>?
    var partialTask: Task<Void, Never>?

    let vad: EnergyVAD
    /// (buffer, duration) ring — last ~preRollMs of audio, replayed into STT.
    var preRoll: [(AVAudioPCMBuffer, TimeInterval)] = []
    var preRollDuration: TimeInterval = 0
    /// Sustained voiced time while speaking — barge-in trigger.
    var bargeGovernor: BargeInGovernor?
    /// True only while audio is actually audible. `.speaking` outlives sound
    /// (Skill / slow lane). Boost only while live, else the mic deafens the user.
    var speakerAudioLive = false
    var levelFrameCounter = 0

    /// Whether responder.respond was called for the current turn.
    var respondStarted = false
    /// Exchange currently on screen — every `.turnBegan`. Follow-up origin check.
    var currentUserTurnID: UUID?
    /// True while the responder event loop is live. Distinguishes mid-generation
    /// from post-generation drain (follow-up preemption differs).
    var generationActive = false

    private var eventContinuations: [UUID: AsyncStream<VoicePipelineEvent>.Continuation] = [:]

    /// Optional session-long transcript. Nil = shipping default; supplying one
    /// can only remember or offer, never take the acoustic path's turn.
    let continuous: (any ContinuousTranscribing)?
    let intakeTuning: IntakePlanner.Tuning
    /// Finalized spans since the last IntakePlanner decision.
    var heardBuffer = ""
    /// Debounce after the last span. Cancelled/rescheduled per span so a pause
    /// mid-thought extends the utterance. PIN: longer than the 850 ms hangover.
    var heardDecisionTask: Task<Void, Never>?
    var continuousTask: Task<Void, Never>?

    var proactiveTask: Task<Void, Never>?

    /// Last query submitted — amend flow's "original".
    var lastFinalTranscript = ""

    /// True while the goodbye is in flight. `handleProactive` refuses; a late
    /// follow-up must not steal the ack's lease.
    var stopExitInProgress = false
    /// Ack currently ending this session. Survives `speaker.flush` suspend so a
    /// stale continuation cannot emit a second stop.
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

    /// Fresh multicast stream. Ends when the session stops. OUT: VoicePipelineEvent.
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

    // MARK: - Test seams (preemption tests drive handleProactive without a mic)

    func setStateForTesting(_ newState: VoicePipelineState) async {
        state = newState
        // Production claims the floor in `start()`. Direct playback seams need
        // the same reservation without opening a microphone.
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
        // Claim the floor before the mic. A text-mode follow-up waiting for
        // quiet must not speak over a just-started voice session.
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
        // No tap format → nothing to hear; the acoustic path fails on its own.
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

        // Detached-routine follow-ups share this speaker when the room is quiet.
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

        // Close logical session before cancellation hops. A last proactive event
        // must see idle, not rebuild follow-up state.
        transition(to: .idle)
        // Drop an ack still suspended in synthesis. External stop wins; stale
        // flush must not emit a second stop command.
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

        // Release physical ownership before the first collaborator await.
        // `continuous.endSession()` may wedge; UI stop must not leave the tap up.
        mic?.stop()
        mic = nil
        proactive.forceStop()
        // Stale ambient marker would make the next session's first barge-in look
        // like it interrupted a remark that ended long ago.
        proactive.ambientCandidateID = nil
        currentUserTurnID = nil
        speakerAudioLive = false
        amendCapture.reset()
        respondStarted = false
        generationActive = false

        // These collaborators belong to this pipeline. Detach cleanup so a wedged
        // Speech shutdown cannot hold the shared session box.
        let retiringTranscriber = transcriber
        Task.detached(priority: .utility) {
            await retiringTranscriber.cancel()
        }
        if let retiringContinuous = continuous {
            Task.detached(priority: .utility) {
                await retiringContinuous.endSession()
            }
        }

        // In-flight claim/handoff must settle before unconditional floor release.
        await voiceFloor.waitForOwnershipOperations()
        await voiceFloor.releaseUnconditionally()

        // Responder cancel is shared with text mode. Drain older cancels, then
        // this stop's cancel, then expose the box as free.
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

    /// Manual interrupt (UI button / hotkey). OUT: same path as acoustic barge-in.
    public func bargeIn() async {
        guard state == .speaking || state == .thinking || state == .transcribing else { return }
        await performBargeIn()
    }
}

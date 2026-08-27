//
//  WakeWordListener.swift
//  MaryVoice
//
//  THE EAR THAT ONLY KNOWS HER NAME. While no voice session is running, this
//  listener holds a microphone of its own — MicCapture + EnergyVAD + one
//  on-device transcriber — and answers exactly one question per utterance:
//  was that a wake phrase? A match emits `.wake`; everything else is
//  DISCARDED — no event, no deposit, no content in any log.
//
//  DELIBERATELY NOT A VoicePipeline. The pipeline being installed is what the
//  rest of the app reads as "voice owns the world" (typed turns drop, the
//  text-mode speaker floor defers, the ambient engine stands down). Standby
//  must be invisible to all of that, so it shares the pipeline's PARTS, never
//  its identity — and it never touches the speaker at all.
//
//  SINGLE-USE, like the pipeline: each arm builds a fresh listener; `stop()`
//  finishes the event streams and the instance is done.
//
//  CPU IS BOUNDED BY THE FIRST WORDS, NOT BY LENGTH. Live partials run
//  `WakePlanner.couldStillWake`; the first "no" cancels transcription for the
//  rest of that utterance. A room conversation costs a breath of on-device
//  STT per utterance, while "Hey Mary, book me a table for four at…" stays
//  transcribable in full up to `maxUtteranceSeconds`.
//

import AVFoundation
import Foundation
import Speech
import os

public struct WakeListenerConfig: Sendable {
    /// Endpointing thresholds — the session's tuned values, with
    /// `voiceProcessing` OFF: there is no session TTS to echo-cancel, and
    /// voice processing is the thing that drags Bluetooth routes into the
    /// call profile. Self-speech is handled by the `selfSpeech` gate instead.
    public var vad: VADConfig
    public var tuning: WakePlanner.Tuning
    /// A wake capture is bounded: past this the utterance is force-closed and
    /// matched with whatever transcribed. A longer monologue was not a wake
    /// attempt; a longer wake REQUEST forwards truncated (documented trade).
    public var maxUtteranceSeconds: TimeInterval
    /// When the system default input is Bluetooth/Continuity, bind the
    /// built-in microphone instead of following the default.
    ///
    /// OFF BY DEFAULT, and the reason is measured, twice: auto-binding a
    /// device the user did not explicitly pick is exactly what the 2026-08-15
    /// live round ruled against — the bound engine and the system default
    /// ping-pong (start/error-35/stop churn across IO contexts), and with
    /// standby as the first live user of the bind path it ended in HAL-client
    /// SIGSEGVs (two crashes, 2026-08-17). Default-follow binds NOTHING and
    /// is the proven path. The cost: AirPods-as-input sit on the call profile
    /// while standby is armed — accepted until the bind path is hardened by
    /// the Settings device picker.
    public var preferBuiltInOverWireless: Bool

    public init(
        vad: VADConfig = VADConfig(voiceProcessing: false),
        tuning: WakePlanner.Tuning = .standard,
        maxUtteranceSeconds: TimeInterval = 12,
        preferBuiltInOverWireless: Bool = false
    ) {
        self.vad = vad
        self.tuning = tuning
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.preferBuiltInOverWireless = preferBuiltInOverWireless
    }
}

public enum WakeEvent: Sendable, Equatable {
    /// The wake phrase was heard. nil remainder = bare wake (greet);
    /// non-nil = "Hey Mary, <request>" — the first turn, ready to forward.
    case wake(remainder: String?)
    /// Standby cannot run (permissions absent, transcription repeatedly
    /// failing). Emitted once; the listener has stopped itself.
    case unavailable(String)
}

public enum WakeListenerError: LocalizedError {
    case notAuthorized
    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone or speech recognition permission is not granted."
        }
    }
}

public actor WakeWordListener {

    private static let log = Logger(subsystem: "MaryVoice", category: "WakeWordListener")
    /// Transcription failures tolerated before standby declares itself dead.
    private static let failureBudget = 3

    private let config: WakeListenerConfig
    private let transcriber: any VoiceTranscriber
    /// The app's "is Mary's own voice in the room?" gate — text-mode TTS
    /// plays while standby listens, and her own reply must never wake her.
    private let selfSpeech: (@Sendable () async -> Bool)?
    /// Test seam: frames arrive here instead of a microphone, and the
    /// permission preflight is skipped.
    private let injectedFrames: AsyncStream<MicFrame>?

    private let vad: EnergyVAD
    private var mic: MicCapture?
    private var frameTask: Task<Void, Never>?
    private var partialTask: Task<Void, Never>?

    private var preRoll: [(AVAudioPCMBuffer, TimeInterval)] = []
    private var preRollDuration: TimeInterval = 0

    private var utteranceOpen = false
    /// Transcriber currently fed for this utterance. Cleared by early abort,
    /// after which the frames still track VAD so the close is clean — the
    /// audio just stops going anywhere.
    private var sttLive = false
    private var utteranceDuration: TimeInterval = 0
    private var consecutiveFailures = 0
    /// After a begin() failure, no new utterance opens until this passes —
    /// without it, VAD re-opens on the very next voiced frame and a single
    /// transient recognizer hiccup burns the whole failure budget in ~300 ms.
    private var openCooldownUntil = Date.distantPast
    private var stopped = false
    /// Invalidates frame/partial work across actor reentrancy. Cancellation is
    /// advisory: a transcriber or self-speech probe may resume normally after
    /// `stop()`, so every suspension boundary also checks this generation.
    private var generation: UInt64 = 0

    private var eventContinuations: [UUID: AsyncStream<WakeEvent>.Continuation] = [:]

    public init(
        config: WakeListenerConfig = WakeListenerConfig(),
        transcriber: (any VoiceTranscriber)? = nil,
        selfSpeech: (@Sendable () async -> Bool)? = nil,
        frameSource: AsyncStream<MicFrame>? = nil
    ) {
        self.config = config
        self.transcriber = transcriber ?? AppleSpeechTranscriber()
        self.selfSpeech = selfSpeech
        self.injectedFrames = frameSource
        self.vad = EnergyVAD(config: config.vad)
    }

    // MARK: - Events

    /// A fresh stream per subscriber; streams end when the listener stops.
    public func events() -> AsyncStream<WakeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<WakeEvent>.makeStream(bufferingPolicy: .unbounded)
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

    private func emit(_ event: WakeEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !stopped, frameTask == nil else { return }
        generation &+= 1
        let runGeneration = generation

        let frames: AsyncStream<MicFrame>
        if let injectedFrames {
            frames = injectedFrames
        } else {
            // STATUS READS ONLY — standby must never be the thing that
            // prompts. The session's own start is where consent is asked.
            guard SFSpeechRecognizer.authorizationStatus() == .authorized,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            else { throw WakeListenerError.notAuthorized }

            let mic = MicCapture(
                voiceProcessing: config.vad.voiceProcessing,
                deviceUID: standbyDeviceUID())
            frames = try mic.start()
            self.mic = mic
        }

        vad.reset()
        preRoll = []
        preRollDuration = 0

        frameTask = Task {
            for await frame in frames {
                if Task.isCancelled { break }
                await self.handle(frame: frame, generation: runGeneration)
            }
        }
    }

    /// Full teardown. When this returns, the standby microphone is DOWN —
    /// `MicCapture.stop()` completes the engine teardown synchronously — so a
    /// session mic starting right after never overlaps this one.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        generation &+= 1
        frameTask?.cancel()
        frameTask = nil
        partialTask?.cancel()
        partialTask = nil
        mic?.stop()
        mic = nil
        await transcriber.cancel()
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations = [:]
    }

    /// The explicit-pick device for standby, or nil for default-follow.
    /// Built-in is preferred over a wireless default so AirPods keep their
    /// listening-quality profile while she merely stands by.
    private func standbyDeviceUID() -> String? {
        guard config.preferBuiltInOverWireless,
              let defaultID = AudioInputDeviceList.defaultInputDeviceID(),
              AudioInputDeviceList.isBluetooth(defaultID)
                  || AudioInputDeviceList.isContinuityCapture(defaultID)
        else { return nil }
        return AudioInputDeviceList.builtInInputUID()
    }

    // MARK: - Frames

    private func handle(frame: MicFrame, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        pushPreRoll(frame)

        guard utteranceOpen else {
            if case .speechStart = vad.process(rms: frame.rms, frameDuration: frame.duration) {
                guard Date() >= openCooldownUntil else {
                    vad.reset()
                    return
                }
                if let selfSpeech {
                    let speaking = await selfSpeech()
                    guard isCurrent(generation), !Task.isCancelled else { return }
                    if speaking {
                        // Her own voice through the room. Not an utterance.
                        vad.reset()
                        return
                    }
                }
                await openUtterance(includeCurrent: frame, generation: generation)
            }
            return
        }

        utteranceDuration += frame.duration
        if sttLive {
            await transcriber.append(frame.buffer)
            guard isCurrent(generation), !Task.isCancelled else { return }
        }

        switch vad.process(rms: frame.rms, frameDuration: frame.duration) {
        case .speechEnd:
            await closeUtterance(generation: generation)
        case .discardedNoise:
            if sttLive { await transcriber.cancel() }
            guard isCurrent(generation), !Task.isCancelled else { return }
            resetUtterance()
        default:
            // The cap: a monologue this long was not a wake attempt, and a
            // wake REQUEST this long is honored truncated rather than
            // transcribed forever.
            if utteranceDuration >= config.maxUtteranceSeconds {
                await closeUtterance(generation: generation)
            }
        }
    }

    private func pushPreRoll(_ frame: MicFrame) {
        preRoll.append((frame.buffer, frame.duration))
        preRollDuration += frame.duration
        let limit = Double(config.vad.preRollMs) / 1000
        while preRollDuration > limit, preRoll.count > 1 {
            let removed = preRoll.removeFirst()
            preRollDuration -= removed.1
        }
    }

    private func openUtterance(includeCurrent frame: MicFrame, generation: UInt64) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        utteranceOpen = true
        utteranceDuration = frame.duration
        sttLive = false

        let format = mic?.format ?? frame.buffer.format
        do {
            try await transcriber.begin(format: format)
        } catch {
            guard isCurrent(generation), !Task.isCancelled else { return }
            await noteTranscriptionFailure(error, generation: generation)
            return
        }
        guard isCurrent(generation), !Task.isCancelled else {
            await transcriber.cancel()
            return
        }
        sttLive = true
        consecutiveFailures = 0

        let partialStream = await transcriber.partials()
        guard isCurrent(generation), !Task.isCancelled else {
            await transcriber.cancel()
            return
        }
        partialTask = Task {
            for await partial in partialStream {
                if Task.isCancelled { break }
                await self.notePartial(partial, generation: generation)
            }
        }

        // Pre-roll replay so "Mary" keeps its first syllable.
        for (buffer, _) in preRoll where buffer !== frame.buffer {
            guard isCurrent(generation), !Task.isCancelled else { return }
            await transcriber.append(buffer)
        }
        guard isCurrent(generation), !Task.isCancelled else { return }
        await transcriber.append(frame.buffer)
    }

    /// The early abort: the first partial that can no longer become a wake
    /// phrase ends transcription for this utterance. The utterance itself
    /// stays open so VAD closes it cleanly; the audio just stops mattering.
    private func notePartial(_ text: String, generation: UInt64) async {
        guard isCurrent(generation), utteranceOpen, sttLive else { return }
        guard !WakePlanner.couldStillWake(partial: text, tuning: config.tuning) else { return }
        sttLive = false
        partialTask?.cancel()
        partialTask = nil
        await transcriber.cancel()
    }

    private func closeUtterance(generation: UInt64) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        let hadTranscription = sttLive
        resetUtterance()
        guard hadTranscription else { return }

        let text = (try? await transcriber.finish()) ?? ""
        guard isCurrent(generation), !Task.isCancelled, !text.isEmpty else { return }
        if let selfSpeech {
            let speaking = await selfSpeech()
            guard isCurrent(generation), !Task.isCancelled else { return }
            if speaking {
                // TTS started mid-utterance — the tail of this audio is hers.
                return
            }
        }
        switch WakePlanner.wake(in: text, tuning: config.tuning) {
        case .bare:
            Self.log.notice("wake phrase heard (bare)")
            emit(.wake(remainder: nil))
        case .request(let remainder):
            Self.log.notice("wake phrase heard (with request)")
            emit(.wake(remainder: remainder))
        case nil:
            // DISCARDED. Counts only, never content.
            break
        }
    }

    private func resetUtterance() {
        utteranceOpen = false
        sttLive = false
        utteranceDuration = 0
        partialTask?.cancel()
        partialTask = nil
        vad.reset()
    }

    private func noteTranscriptionFailure(_ error: Error, generation: UInt64) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        resetUtterance()
        if let transcriberError = error as? TranscriberError,
           case .notAuthorized = transcriberError {
            await declareUnavailable("speech recognition is not authorized")
            return
        }
        consecutiveFailures += 1
        openCooldownUntil = Date().addingTimeInterval(2)
        Self.log.notice("standby transcription failed (\(self.consecutiveFailures)/\(Self.failureBudget))")
        if consecutiveFailures >= Self.failureBudget {
            await declareUnavailable("transcription keeps failing")
        }
    }

    private func declareUnavailable(_ reason: String) async {
        guard !stopped else { return }
        emit(.unavailable(reason))
        await stop()
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        !stopped && generation == candidate
    }
}

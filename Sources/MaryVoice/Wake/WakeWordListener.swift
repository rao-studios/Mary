//
//  WakeWordListener.swift
//  MaryVoice
//
//  WHAT: Standby ear — MicCapture + EnergyVAD + STT, answers "was that a wake?"
//  IN:   app standby arm
//  OUT:  WakeEvent (.wake / .unavailable) — never a VoicePipeline
//  PIN:  Single-use. CPU bounded by first words (couldStillWake abort).
//

import AVFoundation
import Foundation
import Speech
import os

public struct WakeListenerConfig: Sendable {
    /// Session VAD, VP off (no TTS to cancel; VP would drag Bluetooth onto HFP). Self-speech is gated separately.
    public var vad: VADConfig
    public var tuning: WakePlanner.Tuning
    /// Bound a wake capture; force-close past this. Longer requests forward truncated.
    public var maxUtteranceSeconds: TimeInterval
    /// Prefer built-in over a wireless default. PIN: off by default (auto-bind ping-pong).
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
    /// App gate: is Mary's own TTS in the room? Must not wake standby.
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
    /// Transcriber fed this utterance. Cleared on early abort; VAD still closes cleanly.
    private var sttLive = false
    private var utteranceDuration: TimeInterval = 0
    private var consecutiveFailures = 0
    /// After begin() fails, wait before reopening — else one hiccup burns the failure budget.
    private var openCooldownUntil = Date.distantPast
    private var stopped = false
    /// Invalidates in-flight frame/partial work. Check at every suspension; `stop()` is advisory.
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
            // Status reads only — consent is the session start, not standby.
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

    /// When this returns the standby mic is down — a session mic must not overlap it.
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

    /// Explicit pick, or built-in when the default is wireless; else default-follow.
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

    /// First partial that cannot become a wake ends STT; VAD still closes the utterance.
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

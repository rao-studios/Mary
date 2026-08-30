//
//  VoicePipeline+FrameHandling.swift
//  MaryVoice
//
//  WHAT: Per-frame mic loop — VAD, STT feed, amend, barge-in.
//  IN:   MicLoop task → handle(frame:)
//  OUT:  EnergyVAD / AmendCapture / BargeInGovernor / VoiceTranscriber
//

import AVFoundation
import Foundation

extension VoicePipeline {

    // MARK: - Frame handling
    
    // ROUTE: The CORE mic loop
    func handle(frame: MicFrame) async {
        // Cancellation cannot retract an actor call already dispatched.
        // After a stop command matches, logical hearing is closed even though
        // the physical graph stays up until the ack drains.
        guard !stopExitInProgress, state != .idle else { return }
        levelFrameCounter += 1
        if levelFrameCounter % 2 == 0 {
            emit(.audioLevel(min(frame.rms * 8, 1)))
        }

        pushPreRoll(frame)
        // Every frame, every state — continuous hearing of the room.
        // Skip while `speakerAudioLive` so she does not transcribe herself.
        if let continuous, !speakerAudioLive {
            await continuous.appendContinuous(frame.buffer)
            // Stop-listening may have won while the analyzer was suspended.
            // Do not reinterpret this stale frame as barge-in on the ack.
            guard !Task.isCancelled, !stopExitInProgress, state != .idle else {
                return
            }
        }

        switch state {
        case .idle:
            break

        case .listening(utteranceActive: false):
            vad.thresholdBoost = 1.0
            switch vad.process(rms: frame.rms, frameDuration: frame.duration) {
            case .speechStart:
                emit(.vad(.speechStart))
                await openUtterance(includeCurrent: frame)
            default:
                break
            }

        case .listening(utteranceActive: true):
            await transcriber.append(frame.buffer)
            guard !Task.isCancelled, !stopExitInProgress, state != .idle else {
                return
            }
            switch vad.process(rms: frame.rms, frameDuration: frame.duration) {
            case .speechEnd(let duration):
                emit(.vad(.speechEnd(duration: duration)))
                partialTask?.cancel()
                partialTask = nil
                transition(to: .transcribing)
                // ROUTE: Run Turn
                turnTask = Task { await self.runTurn() }
            case .discardedNoise:
                if amendCapture.amendContext != nil {
                    // Correction cannot be "noise" — commit already proved speech.
                    partialTask?.cancel()
                    partialTask = nil
                    transition(to: .transcribing)
                    turnTask = Task { await self.runTurn() }
                } else {
                    await transcriber.cancel()
                    guard !Task.isCancelled, !stopExitInProgress, state != .idle else {
                        return
                    }
                    partialTask?.cancel()
                    partialTask = nil
                    transition(to: .listening(utteranceActive: false))
                }
            default:
                break
            }

        case .transcribing, .thinking:
            // Capture-first, cancel-late. Real speech supersedes; noise does not.
            switch amendCapture.directive(
                rms: frame.rms,
                frameDuration: frame.duration,
                isTranscribing: state == .transcribing
            ) {
            case .none:
                break
            case .beginCapture:
                amendCapture.beginCapture(preRoll: preRoll.map(\.0), duration: preRollDuration)
            case .captureFrame:
                amendCapture.appendFrame(frame.buffer, duration: frame.duration)
            case .discard:
                amendCapture.clearSideCapture()
            case .deferCommit:
                amendCapture.setPendingCommit()
                amendCapture.appendFrame(frame.buffer, duration: frame.duration)
            case .commitNow:
                amendCapture.appendFrame(frame.buffer, duration: frame.duration)
                await commitAmend()
            }

        case .speaking:
            // Pause on onset, commit if sustained, resume if noise.
            // Onset follows live audio, not `.speaking` (that outlives sound).
            if bargeGovernor == nil || bargeGovernor!.onsetRMS != bargeInOnsetRMS {
                // Rebuild discards provisional cadence — resume first so a
                // pause is not left without a matching `.resume`.
                if bargeGovernor?.isProvisional == true {
                    guard let lease = voiceFloor.currentLease else { return }
                    _ = await speaker.resume(lease: lease)
                    guard !Task.isCancelled, !terminated, !stopExitInProgress,
                          state != .idle, voiceFloor.currentLease == lease
                    else {
                        return
                    }
                }
                bargeGovernor = BargeInGovernor(
                    onsetRMS: bargeInOnsetRMS,
                    commitAfter: Double(config.vad.minUtteranceMs) / 1000,
                    retreatAfter: Double(config.vad.bargeResumeMs) / 1000)
            }
            switch bargeGovernor!.process(rms: frame.rms, frameDuration: frame.duration) {
            case .none:
                break
            case .pause:
                guard let lease = voiceFloor.currentLease else { return }
                _ = await speaker.pause(lease: lease)
                guard !terminated, voiceFloor.currentLease == lease else { return }
            case .commit:
                await performBargeIn()
            case .resume:
                guard let lease = voiceFloor.currentLease else { return }
                _ = await speaker.resume(lease: lease)
                guard !terminated, voiceFloor.currentLease == lease else { return }
            }
        }
    }

    /// Barge-in onset for right now: boosted only while Mary's voice is in the room.
    var bargeInOnsetRMS: Float {
        speakerAudioLive
            ? config.vad.speechStartRMS * config.vad.bargeInRMSBoost
            : config.vad.speechStartRMS
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

    // MARK: - Amend flow orchestration

    /// Sustained speech during `.thinking` — tear the in-flight turn down,
    /// hand the mic to the correction. OUT: beginAmendCapture.
    private func commitAmend() async {
        guard !terminated, let lease = voiceFloor.currentLease else { return }
        let original = amendCapture.amendContext?.original ?? lastFinalTranscript
        let wasSubmitted = respondStarted
        turnTask?.cancel()
        turnTask = nil
        voiceFloor.stopWatch()
        guard await voiceFloor.hardStopAndRelease(expecting: lease) else { return }
        if wasSubmitted {
            await voiceFloor.cancelResponder()
            guard !terminated else { return }
        }
        amendCapture.amendContext = (original: original, wasSubmitted: wasSubmitted)
        await beginAmendCapture()
    }

    /// Open the correction utterance: fresh transcriber, side-buffer replay.
    func beginAmendCapture() async {
        emit(.turnSuperseded)
        vad.reset()
        _ = vad.process(rms: config.vad.speechStartRMS * 2, frameDuration: 0.001)  // arm as active
        emit(.vad(.speechStart))
        guard let format = mic?.format else {
            amendCapture.reset()
            transition(to: .listening(utteranceActive: false))
            return
        }
        do {
            try await transcriber.begin(format: format)
        } catch {
            guard !stopExitInProgress, state != .idle else {
                amendCapture.reset()
                return
            }
            emit(.error(error.localizedDescription))
            amendCapture.reset()
            transition(to: .listening(utteranceActive: false))
            return
        }
        guard !Task.isCancelled, !stopExitInProgress, mic != nil,
              state == .thinking || state == .transcribing
        else {
            await transcriber.cancel()
            amendCapture.reset()
            return
        }
        transition(to: .listening(utteranceActive: true))
        let partialStream = await transcriber.partials()
        guard !Task.isCancelled, !stopExitInProgress, mic != nil,
              state == .listening(utteranceActive: true)
        else {
            await transcriber.cancel()
            amendCapture.reset()
            return
        }
        partialTask = Task {
            for await partial in partialStream {
                if Task.isCancelled { break }
                await self.emitPartial(partial)
            }
        }
        let replay = amendCapture.sideBuffer
        amendCapture.clearCaptureAndGovernor()
        for buffer in replay {
            guard !Task.isCancelled, !stopExitInProgress, mic != nil,
                  state == .listening(utteranceActive: true)
            else {
                await transcriber.cancel()
                partialTask?.cancel()
                partialTask = nil
                return
            }
            await transcriber.append(buffer)
        }
    }

    // MARK: - Utterance opening

    /// Begin a transcriber utterance, replaying pre-roll so the first syllable is kept.
    private func openUtterance(includeCurrent frame: MicFrame) async {
        guard let format = mic?.format else { return }
        do {
            try await transcriber.begin(format: format)
        } catch {
            guard !stopExitInProgress, state != .idle else { return }
            emit(.error(error.localizedDescription))
            vad.reset()
            transition(to: .listening(utteranceActive: false))
            return
        }

        // `begin` is an actor hop. Recheck lifecycle before partials/replay.
        guard !Task.isCancelled, !stopExitInProgress, mic != nil,
              state == .listening(utteranceActive: false)
        else {
            await transcriber.cancel()
            return
        }

        transition(to: .listening(utteranceActive: true))

        let partialStream = await transcriber.partials()
        guard !Task.isCancelled, !stopExitInProgress, mic != nil,
              state == .listening(utteranceActive: true)
        else {
            await transcriber.cancel()
            return
        }
        partialTask = Task {
            for await partial in partialStream {
                if Task.isCancelled { break }
                await self.emitPartial(partial)
            }
        }

        for (buffer, _) in preRoll where buffer !== frame.buffer {
            guard !Task.isCancelled, !stopExitInProgress, mic != nil,
                  state == .listening(utteranceActive: true)
            else {
                await transcriber.cancel()
                partialTask?.cancel()
                partialTask = nil
                return
            }
            await transcriber.append(buffer)
        }
        guard !Task.isCancelled, !stopExitInProgress, mic != nil,
              state == .listening(utteranceActive: true)
        else {
            await transcriber.cancel()
            partialTask?.cancel()
            partialTask = nil
            return
        }
        await transcriber.append(frame.buffer)
    }

    func emitPartial(_ text: String) {
        emit(.partialTranscript(text))
    }
}

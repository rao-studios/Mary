//
//  VoicePipeline+FrameHandling.swift
//  MaryVoice
//

import AVFoundation
import Foundation

extension VoicePipeline {

    // MARK: - Frame handling
    
    // ROUTE: The CORE mic loop
    func handle(frame: MicFrame) async {
        // Cancellation alone cannot retract an actor call already dispatched
        // by the mic loop. Once a stop command matches, logical hearing is
        // closed even though the physical graph remains alive until the
        // acknowledgement drains.
        guard !stopExitInProgress, state != .idle else { return }
        levelFrameCounter += 1
        if levelFrameCounter % 2 == 0 {
            emit(.audioLevel(min(frame.rms * 8, 1)))
        }

        pushPreRoll(frame)
        // EVERY FRAME, IN EVERY STATE — the difference between a transcript
        // and an utterance. The per-utterance transcriber below is still fed
        // only while an utterance is open; this one hears the room.
        //
        // Except her own voice: `speakerAudioLive` is playing audio, and
        // feeding that back is how she would end up transcribing herself.
        if let continuous, !speakerAudioLive {
            await continuous.appendContinuous(frame.buffer)
            // Stop-listening may have won while the continuous analyzer was
            // suspended. Do not reinterpret this stale command-tail frame in
            // the new `.speaking` state and pause the acknowledgement.
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
                    // A correction utterance can't be "noise" — the commit
                    // already proved sustained voiced speech (it lives in the
                    // replayed side buffer). Submit whatever was captured.
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
            // The thinking-phase interrupt: capture-first, cancel-late. Real
            // speech supersedes the turn; noise never disturbs it; silence
            // means the user is waiting.
            switch amendCapture.directive(
                rms: frame.rms,
                frameDuration: frame.duration,
                isTranscribing: state == .transcribing
            ) {
            case .none:
                break
            case .beginCapture:
                // Snapshot the pre-roll (it holds the onset syllables) and
                // start buffering — silently; the turn keeps generating.
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
            // The interruption cadence: pause the INSTANT speech crosses the
            // boosted threshold, commit to a full barge-in if it sustains,
            // resume if it was just noise. Pure logic in BargeInGovernor.
            //
            // The onset FOLLOWS THE AUDIO, not the state: `.speaking` outlives
            // the sound, and a boost held over a silent speaker is a deafened
            // mic. Rebuilt only on a genuine transition (the governor's onset
            // is immutable), which is also the only moment the provisional
            // pause/resume cadence can safely restart — nothing is playing.
            if bargeGovernor == nil || bargeGovernor!.onsetRMS != bargeInOnsetRMS {
                // A rebuild discards the provisional cadence, and the pause it
                // already issued would then have no `.resume` to answer it —
                // silently wedged playback. Hand the pause back first: the
                // threshold moved, so the decision starts over.
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

    /// The barge-in onset for RIGHT NOW: boosted only while Mary's own
    /// voice is actually in the room. Silent-but-thinking must be
    /// interruptible at normal volume.
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

    /// Sustained speech during `.thinking` — the "late" moment of
    /// capture-first-cancel-late: tear the in-flight turn down and hand the
    /// mic to the correction utterance.
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

    /// Opens the correction utterance: fresh transcriber session, side-buffer
    /// replay (onset syllables included), live frames continue through the
    /// normal listening-active branch.
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

    /// Begin a transcriber utterance, replaying the pre-roll so the first
    /// syllable isn't clipped.
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

        // `begin` is an actor hop and may suspend behind model/session setup.
        // A stop can win while it is away. Cancellation of the outer mic-loop
        // task does not retract this already-dispatched actor call, so recheck
        // the lifecycle before creating a partials task or appending replayed
        // audio into a transcriber that belongs to a dead session.
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

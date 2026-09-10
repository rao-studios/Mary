//
//  VoicePipeline+ProactivePlayback.swift
//  MaryVoice
//
//  WHAT: Follow-up, progress, ambient, barge-in playback on the shared floor.
//  IN:   ProactiveEvent / performBargeIn
//  OUT:  KokoroStreamSpeaker / LanguageResponder notes / VoicePipelineEvent
//

import Foundation

extension VoicePipeline {

    // MARK: - Proactive follow-up playback

    func handleProactive(_ event: ProactiveEvent) async {
        // Cancelled event loop can still resume once. Idle must not speak.
        guard !terminated, state != .idle else { return }
        // Do not cut the stop-listening goodbye.
        guard !stopExitInProgress else { return }
        switch event {
        case .followUpToken(let token, let origin):
            proactive.appendFollowUpToken(token, origin: origin)
            if proactive.followUpSpeaking {
                guard let lease = proactive.followUpSpeakerLease else {
                    proactive.markStopped()
                    return
                }
                guard await speaker.feed(proactive.followUpBuffer, lease: lease) else {
                    // Newer floor claim won. Clear only this lease's speaking state.
                    proactive.clearSpeaking(ifLeaseIs: lease)
                    return
                }
                return
            }
            guard !proactive.followUpCutInProgress else { return }   // buffer during a cut
            // Stale origin waits for quiet; never cut into a newer reply.
            let stale = FollowUpPriority.isStale(
                origin: proactive.followUpBufferOrigin, currentUserTurnID: currentUserTurnID)
            switch FollowUpPriority.directive(
                state: state, generationActive: generationActive, isStale: stale
            ) {
            case .streamNow:
                // Quiet room — stream live. Watch flips to `.speaking`.
                let expectedFloorLease = voiceFloor.currentLease
                await beginFollowUpStreaming(replacing: expectedFloorLease)
            case .preemptThenStream:
                // Deeper answer outranks in-flight small talk — cancel barge-in-style.
                let expectedFloorLease = voiceFloor.currentLease
                proactive.followUpCutInProgress = true
                guard await preemptTurnForFollowUp(replacing: expectedFloorLease) else {
                    proactive.followUpCutInProgress = false
                    return
                }
                await beginFollowUpStreaming(replacing: expectedFloorLease)
                proactive.followUpCutInProgress = false
            case .yieldThenStream:
                // Generation done, audio draining — yield at sentence boundary.
                let expectedFloorLease = voiceFloor.currentLease
                proactive.followUpCutInProgress = true
                await beginFollowUpStreaming(replacing: expectedFloorLease)
                proactive.followUpCutInProgress = false
            case .buffer:
                break   // the user (or a newer turn) has the floor — buffered
            }
        case .followUpCompleted(let fullText, let origin):
            proactive.replaceFollowUpBuffer(fullText, origin: origin)
            if proactive.followUpSpeaking {
                await finishFollowUpPlayback()
            } else {
                await playFollowUpWhenQuiet()
            }
        case .routineProgress(let line, _):
            await speakRoutineProgress(line)
        case .ambientUtterance(let line, let candidateID):
            await speakAmbientUtterance(line, candidateID: candidateID)
        case .routineCancelled:
            proactive.clearFollowUpBuffer()   // stopped — nothing further to speak
        case .routineSettled:
            // Chip goes dark. Do not clear another routine's buffered follow-up.
            break
        case .routineStarted, .skillInvocation, .skillResult, .autoMemoryTriggered:
            break   // transcript concerns — the app mirrors these
        }
    }

    /// Open live follow-up stream. Fresh physical lease revokes the primary router.
    @discardableResult
    private func beginFollowUpStreaming(replacing expectedFloorLease: UUID?) async -> UUID? {
        guard let lease = await voiceFloor.replace(expecting: expectedFloorLease) else { return nil }
        // Quiet gap still needs the previous writer's draft cleared.
        guard await speaker.softStop(lease: lease, handoff: true), voiceFloor.currentLease == lease else {
            return nil
        }
        proactive.markSpeaking(lease: lease)
        startFollowUpSpeakerWatch(lease: lease)
        guard await speaker.feed(proactive.followUpBuffer, lease: lease) else {
            proactive.clearSpeaking(ifLeaseIs: lease)
            return nil
        }
        return lease
    }

    /// Follow-up arrived mid-generation: cancel like barge-in, cut at sentence boundary.
    private func preemptTurnForFollowUp(replacing expectedFloorLease: UUID?) async -> Bool {
        guard !terminated, voiceFloor.currentLease == expectedFloorLease else { return false }
        turnTask?.cancel()
        turnTask = nil
        voiceFloor.stopWatch()
        await voiceFloor.cancelResponder()
        // `cancel()` is an actor hop. Recheck lease before altering turn state.
        guard !terminated, voiceFloor.currentLease == expectedFloorLease else { return false }
        emit(.turnCancelled)
        respondStarted = false
        generationActive = false
        amendCapture.reset()
        return true
    }

    /// Speaker-event watcher for follow-ups outside a turn. OUT: handleSpeakerEvent.
    private func startFollowUpSpeakerWatch(lease: UUID) {
        voiceFloor.startWatch(lease: lease) { [weak self] event in
            await self?.handleSpeakerEvent(event)
        }
    }

    /// Wait for a quiet room, then speak the buffered follow-up. 15s cap;
    /// past that the moment is gone (text still in transcript).
    private func playFollowUpWhenQuiet() async {
        guard !proactive.followUpBuffer.isEmpty else { return }
        var waitedNanoseconds: UInt64 = 0
        while state != .listening(utteranceActive: false) {
            if state == .idle { proactive.clearFollowUpBuffer(); return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            waitedNanoseconds += 200_000_000
            if waitedNanoseconds > 15_000_000_000 { proactive.clearFollowUpBuffer(); return }
        }
        // Wait may span a new user turn — stale buffer already dropped.
        guard !proactive.followUpBuffer.isEmpty else { return }
        let expectedFloorLease = voiceFloor.currentLease
        guard await beginFollowUpStreaming(replacing: expectedFloorLease) != nil else { return }
        await finishFollowUpPlayback()
    }

    private func finishFollowUpPlayback() async {
        let text = proactive.followUpBuffer
        guard let lease = proactive.followUpSpeakerLease else { return }
        if !text.isEmpty,
           !(await speaker.feed(text, lease: lease)) {
            return
        }
        // A streaming token may arrive while `feed` suspends. Clear only this buffer.
        proactive.clearFollowUpBufferIfUnchanged(from: text)
        await endProactivePlayback(lease: lease)
    }

    /// Drain, drop watch, hand the floor back. Touches no follow-up buffer.
    private func endProactivePlayback(lease: UUID) async {
        guard await speaker.flush(lease: lease) else { return }
        guard proactive.followUpSpeakerLease == lease, voiceFloor.currentLease == lease else { return }
        proactive.markStopped()
        voiceFloor.stopWatch(for: lease)
        emit(.ttsFinished)
        if state == .speaking {
            vad.reset()
            bargeGovernor = nil
            transition(to: .listening(utteranceActive: false))
        }
    }

    /// Progress line: speak only into a quiet room; drop (and record) otherwise.
    /// PIN: never preempt, never hold, never touch the follow-up buffer.
    private func speakRoutineProgress(_ line: String) async {
        // Empty line — no ledger row.
        guard !line.isEmpty else { return }
        guard !proactive.followUpSpeaking, !proactive.followUpCutInProgress, !generationActive,
              state == .listening(utteranceActive: false)
        else {
            await responder.noteProgressDropped(line)
            return
        }
        await performCannedPlayback(line)
    }

    /// Claim→feed→drain core for progress and canned lines. `followUpSpeaking`
    /// holds the proactive floor so a second line cannot stack on this one.
    @discardableResult
    func performCannedPlayback(_ line: String) async -> Bool {
        let expectedFloorLease = voiceFloor.currentLease
        guard let lease = await voiceFloor.replace(expecting: expectedFloorLease) else { return false }
        // Matching follow-up handoff: clear the preceding writer's draft.
        guard await speaker.softStop(lease: lease, handoff: true), voiceFloor.currentLease == lease else {
            return false
        }
        proactive.markSpeaking(lease: lease)
        startFollowUpSpeakerWatch(lease: lease)
        guard await speaker.feed(line, lease: lease) else {
            proactive.clearSpeaking(ifLeaseIs: lease)
            return false
        }
        await endProactivePlayback(lease: lease)
        return true
    }

    /// Quiet-floor predicate shared by the hold loop and the claim.
    private var ambientFloorIsClear: Bool {
        state == .listening(utteranceActive: false)
            && !proactive.followUpSpeaking && !proactive.followUpCutInProgress && !generationActive
    }

    /// Unprompted remark. PIN: never preempt, never touch follow-up buffer;
    /// may wait up to `AmbientVoiceFloor.quietBudget`. Every exit books a row.
    private func speakAmbientUtterance(_ line: String, candidateID: UUID) async {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty line — no ledger row.
        guard !text.isEmpty else { return }

        var waited: TimeInterval = 0
        var recordedHold = false
        while true {
            if state == .idle {
                await responder.noteAmbientDelivery(.sessionEnded, for: candidateID)
                return
            }
            // User is talking — yield, do not delay-interrupt.
            if state == .listening(utteranceActive: true) || state == .transcribing {
                await responder.noteAmbientDelivery(.preemptedByUser, for: candidateID)
                return
            }
            switch AmbientVoiceFloor.verdict(floorIsClear: ambientFloorIsClear, waited: waited) {
            case .speakNow:
                break
            case .drop:
                await responder.noteAmbientDelivery(.droppedStale, for: candidateID)
                return
            case .waitForQuiet:
                if !recordedHold {
                    recordedHold = true
                    await responder.noteAmbientDelivery(.heldForQuiet, for: candidateID)
                }
                try? await Task.sleep(nanoseconds: AmbientVoiceFloor.pollNanoseconds)
                waited += AmbientVoiceFloor.pollInterval
                continue
            }
            break
        }

        // Same claim as the progress line: fresh lease, clear draft, feed.
        let expectedFloorLease = voiceFloor.currentLease
        guard let lease = await voiceFloor.replace(expecting: expectedFloorLease) else {
            await responder.noteAmbientDelivery(.preemptedByUser, for: candidateID)
            return
        }
        guard await speaker.softStop(lease: lease, handoff: true),
              voiceFloor.currentLease == lease
        else {
            await responder.noteAmbientDelivery(.preemptedByUser, for: candidateID)
            return
        }
        proactive.markSpeaking(lease: lease)
        proactive.ambientCandidateID = candidateID
        startFollowUpSpeakerWatch(lease: lease)
        guard await speaker.feed(text, lease: lease) else {
            proactive.clearSpeaking(ifLeaseIs: lease)
            proactive.ambientCandidateID = nil
            await responder.noteAmbientDelivery(.preemptedByUser, for: candidateID)
            return
        }
        await endProactivePlayback(lease: lease)
        // Barge-in during playback already booked this candidate.
        guard proactive.ambientCandidateID == candidateID else { return }
        proactive.ambientCandidateID = nil
        await responder.noteAmbientDelivery(.spoke, for: candidateID)
    }

    func performBargeIn() async {
        guard !terminated, let lease = voiceFloor.currentLease else { return }
        // The interruption's own audio (onset → commit). nil for a manual interrupt.
        let captured = bargeCapture
        bargeCapture = nil
        // A remark is not a turn — do not cancel the responder or emit
        // `.turnCancelled`. `ambientCandidateID` is the engine's negative signal.
        let interruptedAmbient = proactive.ambientCandidateID
        proactive.ambientCandidateID = nil
        turnTask?.cancel()
        turnTask = nil
        voiceFloor.stopWatch()
        guard await voiceFloor.hardStopAndRelease(expecting: lease) else { return }
        if let interruptedAmbient {
            await responder.noteAmbientDelivery(.preemptedByUser, for: interruptedAmbient)
        } else {
            await voiceFloor.cancelResponder()
        }
        guard !terminated else { return }
        await transcriber.cancel()
        guard !terminated else { return }
        // Interrupted turn ends with no replacement — finalize the bubble.
        if interruptedAmbient == nil {
            emit(.turnCancelled)
        }
        amendCapture.reset()
        respondStarted = false
        generationActive = false
        speakerAudioLive = false
        // A barged-in follow-up is dropped (its text is in the transcript).
        proactive.forceStop()

        // Collaborators may suspend. Do not open a replacement after stop won.
        guard !Task.isCancelled, !terminated, !stopExitInProgress, state != .idle,
              mic != nil
        else { return }

        // Open a fresh utterance from the interrupting speech — the capture
        // from its onset, or pre-roll for a manual interrupt.
        let replay = captured ?? preRoll.map(\.0)
        vad.reset()
        _ = vad.process(rms: config.vad.speechStartRMS * 2, frameDuration: 0.001)  // arm as active
        emit(.vad(.speechStart))
        guard let format = mic?.format else {
            transition(to: .listening(utteranceActive: false))
            return
        }
        do {
            try await beginTranscriberUtterance(format: format)
        } catch {
            guard !stopExitInProgress, state != .idle else { return }
            emit(.error(error.localizedDescription))
            transition(to: .listening(utteranceActive: false))
            return
        }
        guard !Task.isCancelled, !stopExitInProgress, mic != nil,
              state != .idle
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
        for buffer in replay {
            guard !Task.isCancelled, !stopExitInProgress, mic != nil,
                  state == .listening(utteranceActive: true)
            else {
                await transcriber.cancel()
                partialTask?.cancel()
                partialTask = nil
                return
            }
            await feedTranscriber(buffer)
        }
    }
}

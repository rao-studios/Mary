//
//  VoicePipeline+ProactivePlayback.swift
//  MaryVoice
//

import Foundation

extension VoicePipeline {

    // MARK: - Proactive follow-up playback

    func handleProactive(_ event: ProactiveEvent) async {
        // `proactiveTask` is cancelled at session stop, but its event loop can
        // still resume once. An idle pipeline has no right to resurrect the
        // voice reservation or speak a late routine result.
        guard !terminated, state != .idle else { return }
        // Nor may anything cut in on the stop-listening goodbye: the session
        // is over the moment that command matched, and this arm's own lease
        // takeover would clip the ack mid-word.
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
                    // A new utterance/floor claim won while this token was in
                    // flight. Only clear the exact stale follow-up state;
                    // a newer follow-up may already have installed its own
                    // lease while this actor hop was suspended.
                    proactive.clearSpeaking(ifLeaseIs: lease)
                    return
                }
                return
            }
            guard !proactive.followUpCutInProgress else { return }   // buffer during a cut
            // THE ORIGIN GATE. A follow-up narrating an OLDER exchange has no
            // claim on the floor while a newer reply owns it — taking the cut
            // path there splices turn N's read onto turn N+1's answer at a
            // sentence boundary, which is exactly what the user heard: "the
            // result pipes in later and appends to the response that answered
            // the new query." A stale origin may only ever reach the ear
            // through playFollowUpWhenQuiet — wait for the room, never cut
            // into it. (`submitTurn`'s stale-drop covers only a buffer that
            // PRE-dates the new query; this covers one that arrives after it.)
            let stale = FollowUpPriority.isStale(
                origin: proactive.followUpBufferOrigin, currentUserTurnID: currentUserTurnID)
            switch FollowUpPriority.directive(
                state: state, generationActive: generationActive, isStale: stale
            ) {
            case .streamNow:
                // The room is quiet — stream the follow-up live. The speaker
                // watch flips us to .speaking on first audio. Quiet is quiet:
                // even stale narration is welcome when nothing is playing.
                let expectedFloorLease = voiceFloor.currentLease
                await beginFollowUpStreaming(replacing: expectedFloorLease)
            case .preemptThenStream:
                // The deeper answer outranks an in-flight small-talk turn:
                // cancel it barge-in-style (partial text kept) and take the
                // floor at the sentence boundary.
                let expectedFloorLease = voiceFloor.currentLease
                proactive.followUpCutInProgress = true
                guard await preemptTurnForFollowUp(replacing: expectedFloorLease) else {
                    proactive.followUpCutInProgress = false
                    return
                }
                await beginFollowUpStreaming(replacing: expectedFloorLease)
                proactive.followUpCutInProgress = false
            case .yieldThenStream:
                // Generation is done, audio is still draining — yield at the
                // sentence boundary, then the follow-up speaks.
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
            // Settle is bookkeeping only (the chip goes dark). With several
            // routines, one settling must NOT clear another's follow-up that
            // sits buffered waiting for a quiet room — and the spoken
            // follow-up now ARRIVES AFTER its routine settles (the brain
            // settles first, then speaks through the serialized chain).
            break
        case .routineStarted, .skillInvocation, .skillResult, .autoMemoryTriggered:
            break   // transcript concerns — the app mirrors these
        }
    }

    /// Open the live follow-up stream: whatever is buffered speaks now and
    /// later tokens feed incrementally. A follow-up receives a FRESH physical
    /// speaker lease, which revokes the still-streaming primary router before
    /// it can append another token during this line's drain.
    @discardableResult
    private func beginFollowUpStreaming(replacing expectedFloorLease: UUID?) async -> UUID? {
        guard let lease = await voiceFloor.replace(expecting: expectedFloorLease) else { return nil }
        // Even in a quiet gap, the previous writer can have an unsynthesized
        // text draft or a synthesis task in flight. A conditional soft stop
        // clears it; when audio is live it preserves the existing
        // sentence-boundary yield.
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

    /// A follow-up arrived mid-generation: end the in-flight turn the way a
    /// barge-in would (responder keeps the partial text; the app finalizes
    /// the streaming bubble) and cut its audio at the sentence boundary.
    private func preemptTurnForFollowUp(replacing expectedFloorLease: UUID?) async -> Bool {
        guard !terminated, voiceFloor.currentLease == expectedFloorLease else { return false }
        turnTask?.cancel()
        turnTask = nil
        voiceFloor.stopWatch()
        await voiceFloor.cancelResponder()
        // `cancel()` is an actor hop. If a newer utterance took the floor
        // while it was in flight, this old routine may no longer alter turn
        // state or proceed to the speaker handoff.
        guard !terminated, voiceFloor.currentLease == expectedFloorLease else { return false }
        emit(.turnCancelled)
        respondStarted = false
        generationActive = false
        amendCapture.reset()
        return true
    }

    /// The speaker-event watcher runs per normal turn; follow-ups outside a
    /// turn need their own so .speaking/.ttsChunkStarted still flow.
    private func startFollowUpSpeakerWatch(lease: UUID) {
        voiceFloor.startWatch(lease: lease) { [weak self] event in
            await self?.handleSpeakerEvent(event)
        }
    }

    /// Wait for a quiet room (listening, no utterance), then speak the
    /// buffered follow-up. With preemption, this path only survives when the
    /// USER holds the floor (mid-utterance/transcription) — 15s covers an
    /// utterance plus its reply; past that the moment is gone (the
    /// transcript still shows the text). Gives up quietly on session end.
    private func playFollowUpWhenQuiet() async {
        guard !proactive.followUpBuffer.isEmpty else { return }
        var waitedNanoseconds: UInt64 = 0
        while state != .listening(utteranceActive: false) {
            if state == .idle { proactive.clearFollowUpBuffer(); return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            waitedNanoseconds += 200_000_000
            if waitedNanoseconds > 15_000_000_000 { proactive.clearFollowUpBuffer(); return }
        }
        // The wait may span a whole NEW user turn — which drops a stale
        // buffer (topic change = acknowledgement). Nothing left to speak.
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
        // A streaming token may arrive while `feed` suspends. Only clear the
        // exact finalized buffer; never erase the next line's accumulation.
        proactive.clearFollowUpBufferIfUnchanged(from: text)
        await endProactivePlayback(lease: lease)
    }

    /// The tail BOTH proactive utterances share: drain, drop the watch, hand
    /// the floor back. Factored out of `finishFollowUpPlayback` precisely
    /// because it touches no buffer — which is what lets the progress line
    /// reuse it without going anywhere near the follow-up buffer.
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

    /// "STILL WORKING ON …" — spoken ONLY into a genuinely quiet room, and
    /// DROPPED rather than buffered when the room is not.
    ///
    /// Three things it may not do, and the guards are in that order:
    ///
    /// 1. IT MAY NOT PREEMPT. The follow-up arm above cuts into a live turn
    ///    (`preemptTurnForFollowUp`) because a finished ANSWER outranks
    ///    small talk. A statement that there is no answer yet outranks
    ///    nothing, so `generationActive` and every non-quiet state simply
    ///    return.
    /// 2. IT MAY NOT BE HELD. `playFollowUpWhenQuiet` waits up to 15 s for a
    ///    pause because an answer is still an answer late. A progress line
    ///    that lands 15 s after the moment it describes is worse than
    ///    silence — it reports a wait the user has already stopped having.
    /// 3. IT MAY NOT TOUCH the follow-up buffer. That buffer belongs to a
    ///    pending ANSWER; appending to it would splice "Still working…" onto
    ///    the front of the result, which is the late-append bug in a new
    ///    costume. Nothing here reads or writes it — the line goes straight
    ///    to the speaker and is gone.
    ///
    /// AND THE DROP IS RECORDED. The timing stays exactly as it is — that was
    /// the user's decision, and holding a progress line is worse than losing
    /// one — but this gate is HARD, SILENT and ONE-SHOT: each mark fires once,
    /// so a mark that lands while the user is mid-utterance is consumed forever
    /// with no retry and no trace, and a turn that loses both can sit silent
    /// from 0 to 420 s with nothing anywhere saying two promises were
    /// destroyed. `noteProgressDropped` books it in the responder's own
    /// delivery ledger, in the vocabulary that ledger already has for exactly
    /// this ("the moment had passed") rather than a parallel one.
    private func speakRoutineProgress(_ line: String) async {
        // An empty line owed nothing, so losing it costs nothing — no row.
        guard !line.isEmpty else { return }
        guard !proactive.followUpSpeaking, !proactive.followUpCutInProgress, !generationActive,
              state == .listening(utteranceActive: false)
        else {
            await responder.noteProgressDropped(line)
            return
        }
        await performCannedPlayback(line)
    }

    /// The claim→feed→drain core `speakRoutineProgress` and `speakCannedLine`
    /// share. `followUpSpeaking` claims the proactive floor for the duration,
    /// so a second line (or a cut) cannot land on top of this one; a real
    /// follow-up's tokens queue behind it through the arm above, which is
    /// exactly the ordering we want — the answer follows the notice.
    @discardableResult
    func performCannedPlayback(_ line: String) async -> Bool {
        let expectedFloorLease = voiceFloor.currentLease
        guard let lease = await voiceFloor.replace(expecting: expectedFloorLease) else { return false }
        // See the matching follow-up handoff: a quiet room still needs the
        // preceding writer's draft cleared before this one starts.
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

    /// IS THE FLOOR OURS? Every condition that must hold before an unprompted
    /// line may be spoken, in one place so the hold loop and the claim cannot
    /// disagree about what "quiet" means.
    private var ambientFloorIsClear: Bool {
        state == .listening(utteranceActive: false)
            && !proactive.followUpSpeaking && !proactive.followUpCutInProgress && !generationActive
    }

    /// SHE VOLUNTEERED SOMETHING — and this arm outranks NOTHING AT ALL.
    ///
    /// THE FAILURE THIS EXISTS TO PREVENT: the obvious way to ship unprompted
    /// speech is `.followUpCompleted(origin: nil)`, which looks like a quiet
    /// standalone lane and is in fact the highest priority in the system. A
    /// nil origin is never stale (`FollowUpPriority.isStale`), so the
    /// follow-up arm reaches `preemptTurnForFollowUp` and CANCELS whatever
    /// the user is being answered right now — pinned, deliberately, by
    /// `FollowUpPreemptionTests.midGenerationFollowUpCancelsTheTurn`. Mary
    /// would abandon an answer mid-sentence to remark on the weather.
    ///
    /// So this is modelled on `speakRoutineProgress`, not on the follow-up
    /// path, and it keeps that method's three rules:
    /// - it NEVER preempts. No `preemptTurnForFollowUp`, no responder cancel.
    /// - it NEVER touches the follow-up buffer. It reuses
    ///   `endProactivePlayback`, which was factored out of
    ///   `finishFollowUpPlayback` precisely because it goes nowhere near that
    ///   buffer — so a routine's buffered answer cannot be spliced or erased
    ///   by a remark landing on top of it.
    /// - it is DROPPABLE. Worth hearing in the pause it describes and worth
    ///   nothing after it.
    ///
    /// AND IT DIFFERS FROM PROGRESS IN ONE WAY: progress is one-shot and dies
    /// instantly if the room is busy, because a wait announced late is worse
    /// than an unannounced one. A remark may WAIT — briefly, bounded by
    /// `AmbientVoiceFloor.quietBudget` — because landing in the next pause is
    /// exactly right for it.
    ///
    /// EVERY EXIT BOOKS A ROW. `noteAmbientDelivery` is the only way the
    /// engine learns that its candidate never reached a room, and a silence
    /// nobody records is the blind spot the whole trace exists to close.
    private func speakAmbientUtterance(_ line: String, candidateID: UUID) async {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty line owed nothing, so losing it costs nothing — no row.
        guard !text.isEmpty else { return }

        var waited: TimeInterval = 0
        var recordedHold = false
        while true {
            if state == .idle {
                await responder.noteAmbientDelivery(.sessionEnded, for: candidateID)
                return
            }
            // THE USER IS TALKING. Not a wait — a yield. Their utterance is
            // about to become a turn, and holding a remark against it only to
            // speak it afterwards is how a remark becomes an interruption
            // wearing a delay. It also gives the engine its cleanest negative
            // signal, which nothing else on this path can supply.
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

        // From here the claim is the progress line's, verbatim: take a fresh
        // physical lease, clear the previous writer's draft, then feed. The
        // room is already quiet, so `softStop` cuts no audible speech.
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
        // A BARGE-IN DURING PLAYBACK ALREADY BOOKED THIS CANDIDATE and cleared
        // the marker. Booking `.spoke` on top would overwrite the one negative
        // signal the governance loop has — the row would say she was heard
        // when she was talked over.
        guard proactive.ambientCandidateID == candidateID else { return }
        proactive.ambientCandidateID = nil
        await responder.noteAmbientDelivery(.spoke, for: candidateID)
    }

    func performBargeIn() async {
        guard !terminated, let lease = voiceFloor.currentLease else { return }
        // WHAT IS ACTUALLY BEING INTERRUPTED?
        //
        // A REMARK IS NOT A TURN. When the thing on the floor is an unprompted
        // line there is no in-flight answer to abandon and no transcript
        // bubble to finalize — so cancelling the responder would reach past
        // the pipeline and kill whatever TEXT turn happened to be generating
        // in the background, and `.turnCancelled` would delete that turn's
        // bubble. The user talked over a remark; nothing they asked for should
        // die for it.
        //
        // `ambientCandidateID` is non-nil only while `speakAmbientUtterance`
        // holds the floor, and that arm refuses to start unless
        // `!generationActive`, so this is precisely scoped: an ordinary
        // barge-in, a routine follow-up, and a drain all behave exactly as
        // before.
        //
        // AND IT IS THE ENGINE'S ONE NEGATIVE SIGNAL. Without this booking,
        // being talked over is indistinguishable from being heard, and the
        // governance loop has nothing to learn from.
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
        // The interrupted turn ends with no replacement text — let the app
        // finalize its transcript bubble (the old orphan-bubble bug).
        if interruptedAmbient == nil {
            emit(.turnCancelled)
        }
        amendCapture.reset()
        respondStarted = false
        generationActive = false
        speakerAudioLive = false
        // A barged-in follow-up is dropped (its text is in the transcript).
        proactive.forceStop()

        // Any collaborator above may suspend. An external stop closes the
        // lifecycle before it awaits those collaborators, so do not open a
        // replacement utterance after that stop has already won.
        guard !Task.isCancelled, !terminated, !stopExitInProgress, state != .idle,
              mic != nil
        else { return }

        // The pre-roll holds the speech that interrupted; open a fresh
        // utterance from it.
        vad.reset()
        _ = vad.process(rms: config.vad.speechStartRMS * 2, frameDuration: 0.001)  // arm as active
        emit(.vad(.speechStart))
        guard let format = mic?.format else {
            transition(to: .listening(utteranceActive: false))
            return
        }
        do {
            try await transcriber.begin(format: format)
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
        for (buffer, _) in preRoll {
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
}

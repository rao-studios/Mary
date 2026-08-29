//
//  VoicePipeline+Turn.swift
//  MaryVoice
//

import Foundation

extension VoicePipeline {

    // MARK: - The turn

    /// Deterministic amend join (user decision): the models interpret the
    /// correction; no extra model pass sanitizes it.
    static let amendJoinSeparator = " — "

    // ROUTE: Entry point for processing a completed turn from the transcriber
    func runTurn() async {
        let text: String
        do {
            text = try await transcriber.finish()
        } catch {
            guard !Task.isCancelled, !stopExitInProgress, state != .idle else {
                return
            }
            // Nothing intelligible.
            if amendCapture.amendContext != nil {
                // The correction audio defeated STT — fall back to just the
                // original query rather than dropping the turn.
                await submitTurn(correction: "")
                return
            }
            // Quietly re-arm.
            transition(to: .listening(utteranceActive: false))
            vad.reset()
            return
        }
        guard !Task.isCancelled, !stopExitInProgress, state != .idle else {
            return
        }

        if amendCapture.pendingAmendCommit {
            // The user superseded while THIS transcript was resolving — it
            // becomes the amend's "original"; the correction is in the side
            // buffer, never submitted anywhere yet.
            amendCapture.amendContext = (original: text, wasSubmitted: false)
            await beginAmendCapture()
            return
        }

        if amendCapture.amendContext != nil {
            await submitTurn(correction: text)
        } else if await interceptStopListening(text) {
            // A session command, not a query — intercepted at the seam
            // where "the model never sees it" is enforceable (decideHeard's
            // IntakePlanner is the in-pipeline matching precedent).
        } else {
            emit(.finalTranscript(text))
            await submitTurn(query: text, superseding: false)
        }
    }

    // ROUTE: SubmitTurn is reused by continous hearing
    /// Composes the amended query and submits it, superseding the aborted
    /// turn when it had already reached the responder.
    private func submitTurn(correction: String) async {
        guard let amend = amendCapture.amendContext else { return }
        amendCapture.amendContext = nil
        let trimmed = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: String
        if amend.original.isEmpty {
            query = trimmed
        } else if trimmed.isEmpty {
            query = amend.original
        } else {
            query = amend.original + Self.amendJoinSeparator + trimmed
        }
        guard !query.isEmpty else {
            transition(to: .listening(utteranceActive: false))
            vad.reset()
            return
        }
        emit(.amendedTranscript(query))
        await submitTurn(query: query, superseding: amend.wasSubmitted)
    }
    
    // ROUTE: Execute turn
    func submitTurn(query: String, superseding: Bool) async {
        guard !terminated else { return }
        // The user has the floor with a NEW utterance. Any old detached
        // buffer—whether waiting, speaking, or halfway through a cut—belongs
        // to work they have moved past. The fresh lease below rejects its
        // in-flight speaker calls; clear its local state here too so it cannot
        // be revived by the next proactive token.
        proactive.forceStop()
        transition(to: .thinking)
        lastFinalTranscript = query
        // A new turn starts silent — whatever the last turn's audio state
        // was, nothing is playing yet, so the mic must not be pre-deafened.
        speakerAudioLive = false
        // A new voice utterance is a hard barge-in boundary even if the prior
        // model task has already finished and only its TTS drain remains.
        guard let speakerLease = await voiceFloor.claim() else { return }

        // Watch the speaker so `speaking` begins exactly when audio does.
        guard await voiceFloor.watchInline(expecting: speakerLease, onEvent: { event in
            await self.handleSpeakerEvent(event)
        }) else { return }

        var accumulated = ""
        // Server-voiced turns (realtime Seer route): the router decides what
        // the local speaker gets vs. what rides the remote-PCM seam.
        var router = SpeechRouter(speaker: speaker, speakerLease: speakerLease)
        do {
            respondStarted = true
            generationActive = true
            defer { generationActive = false }
            let events = superseding
                ? responder.respondSuperseding(query)
                : responder.respond(to: query)
            for try await event in events {
                if Task.isCancelled { break }
                switch event {
                case .turnBegan(let id):
                    // The exchange now on screen. Every later follow-up's
                    // origin is judged against this.
                    currentUserTurnID = id
                    emit(.turnBegan(id))
                case .routineDetached(let id):
                    emit(.routineDetached(id))
                case .exchangeSuperseded(let id):
                    // The superseded turn — possibly a TEXT turn — may still
                    // be draining shared-speaker audio. `submitTurn` claimed
                    // this turn's fresh voice floor before opening the stream,
                    // which already performed the atomic hard stop; doing a
                    // second unleased stop here would revoke THIS router.
                    emit(.exchangeSuperseded(userTurnID: id))
                case .token(let token):
                    accumulated += token
                    emit(.brainToken(token))
                    // Re-checked AT THE CALL, not just at the top of the
                    // loop: reaching the speaker is an actor hop, and a
                    // barge-in or supersede can land inside it. A cancelled
                    // turn that still feeds hands the speaker a string
                    // belonging to nobody's current baseline — the splice
                    // this slice exists to kill. The speaker's own prefix
                    // check is the backstop; this is the gate.
                    guard !Task.isCancelled else { continue }
                    await router.consumeToken(accumulated: accumulated)
                case .speechSource(let source):
                    router.consumeSpeechSource(source, accumulated: accumulated)
                case .retractSpeech:
                    // Guarded AT THE CALL for the same reason `.token` is:
                    // retracting reaches the SHARED speaker across an actor
                    // hop, and a barge-in or supersede landing inside it would
                    // have this dead turn soft-stop the new turn's audio.
                    // `accumulated` is deliberately left standing — the
                    // takeover rewinds the ear, never the transcript.
                    guard !Task.isCancelled else { continue }
                    await router.consumeRetractSpeech(accumulated: accumulated)
                case .audioChunk(let pcm, let sampleRate):
                    await router.consumeAudioChunk(pcm, sampleRate: sampleRate)
                case .skillInvocation(let reference, let argumentsJSON, let runID):
                    emit(.skillInvocation(
                        reference: reference, argumentsJSON: argumentsJSON, runID: runID))
                case .skillResult(let record):
                    emit(.skillResult(record: record))
                case .contribution(let json):
                    emit(.contribution(json: json))
                case .completed(let fullText):
                    accumulated = fullText
                    emit(.assistantReply(fullText))
                case .autoMemoryTriggered:
                    emit(.autoMemoryTriggered)
                }
            }
        } catch {
            emit(.error(error.localizedDescription))
        }

        guard !Task.isCancelled else { return }

        await router.finish()
        guard !Task.isCancelled, self.voiceFloor.currentLease == speakerLease else { return }
        emit(.ttsFinished)
        voiceFloor.stopWatch(for: speakerLease)

        // Auto re-arm: the conversational loop.
        if state != .idle {
            vad.reset()
            bargeGovernor = nil
            amendCapture.resetGovernor()
            respondStarted = false
            speakerAudioLive = false
            transition(to: .listening(utteranceActive: false))
        }
    }

    func handleSpeakerEvent(_ event: SpeakerEvent) {
        switch event {
        case .started:
            // .thinking → normal reply; .listening(false) → follow-up
            // playback. Either way, .speaking arms the boosted barge-in
            // governor so the user can interrupt.
            speakerAudioLive = true
            if state == .thinking || state == .listening(utteranceActive: false) {
                transition(to: .speaking)
            }
        case .chunkScheduled(let text):
            // Audio is queued on the player again — re-arm the boost BEFORE
            // it becomes audible, so her own voice never trips the mic.
            speakerAudioLive = true
            emit(.ttsChunkStarted(text))
        case .audioIdle, .drained, .stopped:
            // The room went quiet while the turn stays open (or the turn
            // ended). Demote the onset: there is no echo left to guard
            // against, and holding the boost is what swallowed the user's
            // normal-volume speech and made the reply arrive late. `.paused`
            // is deliberately NOT here — a provisional barge-in is exactly
            // when the boosted cadence must survive to decide.
            speakerAudioLive = false
        default:
            break
        }
    }
}

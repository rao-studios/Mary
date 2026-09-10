//
//  VoicePipeline+Turn.swift
//  MaryVoice
//
//  WHAT: One conversational turn — transcribe, intercept, submit, speak.
//  IN:   VoicePipeline.handle (endpoint / amend) → this
//  OUT:  VoiceTranscriber / LanguageResponder / SpeechRouter / VoicePipelineEvent
//

import Foundation

extension VoicePipeline {

    // MARK: - The turn

    /// Deterministic amend join. PIN: models interpret the correction; no extra pass.
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
                // Correction audio defeated STT — keep the original query.
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
            // User superseded while this transcript was resolving — it becomes
            // the amend original; correction is in the side buffer.
            amendCapture.amendContext = (original: text, wasSubmitted: false)
            await beginAmendCapture()
            return
        }

        if amendCapture.amendContext != nil {
            await submitTurn(correction: text)
        } else if await interceptStopListening(text) {
            // Session command, not a query — intercepted before the responder.
        } else {
            emit(.finalTranscript(text))
            await submitTurn(query: text, superseding: false)
        }
    }

    // ROUTE: SubmitTurn is reused by continous hearing
    /// Compose amended query and submit, superseding if the aborted turn reached the responder.
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
        // The user has the floor with a new utterance. Drop stale follow-up
        // state; the fresh lease rejects in-flight speaker calls.
        proactive.forceStop()
        transition(to: .thinking)
        lastFinalTranscript = query
        // New turn starts silent — do not pre-deafen the mic.
        speakerAudioLive = false
        // Voice utterance is a hard barge-in boundary even if only TTS drain remains.
        guard let speakerLease = await voiceFloor.claim() else { return }

        // Watch the speaker so `speaking` begins exactly when audio does.
        guard await voiceFloor.watchInline(expecting: speakerLease, onEvent: { event in
            await self.handleSpeakerEvent(event)
        }) else { return }

        var accumulated = ""
        // Server-voiced turns: router splits local tokens vs remote PCM.
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
                    currentUserTurnID = id
                    emit(.turnBegan(id))
                case .routineDetached(let id):
                    emit(.routineDetached(id))
                case .exchangeSuperseded(let id):
                    // This turn already claimed a fresh floor (hard stop). Do
                    // not unleased-stop here — that would revoke this router.
                    emit(.exchangeSuperseded(userTurnID: id))
                case .token(let token):
                    accumulated += token
                    emit(.brainToken(token))
                    // Re-check at the call: actor hop to speaker; barge-in can
                    // land inside it. Cancelled turn must not splice stale text.
                    guard !Task.isCancelled else { continue }
                    await router.consumeToken(accumulated: accumulated)
                case .speechSource(let source):
                    router.consumeSpeechSource(source, accumulated: accumulated)
                case .retractSpeech:
                    // Same gate as `.token`. Leave `accumulated` — rewind the
                    // ear, never the transcript.
                    guard !Task.isCancelled else { continue }
                    await router.consumeRetractSpeech(accumulated: accumulated)
                case .audioChunk(let pcm, let sampleRate):
                    await router.consumeAudioChunk(pcm, sampleRate: sampleRate)
                case .skillInvocation(let reference, let argumentsJSON, let runID):
                    emit(.skillInvocation(
                        reference: reference, argumentsJSON: argumentsJSON, runID: runID))
                case .skillResult(let record):
                    emit(.skillResult(record: record))
                case .ownReads(let records):
                    emit(.ownReads(records))
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
            // `.thinking` → reply; `.listening(false)` → follow-up. Either
            // way `.speaking` arms boosted barge-in.
            speakerAudioLive = true
            if state == .thinking || state == .listening(utteranceActive: false) {
                transition(to: .speaking)
            }
        case .chunkScheduled(let text):
            // Audio queued — re-arm boost before it is audible.
            speakerAudioLive = true
            emit(.ttsChunkStarted(text))
        case .audioIdle, .drained, .stopped:
            // Room quiet (turn may stay open). Drop the boost. PIN: `.paused`
            // stays boosted — provisional barge-in still deciding.
            speakerAudioLive = false
        default:
            break
        }
    }
}

//
//  VoiceService.Session.swift
//  Mary
//
//  Start: build the pipeline from configuration, start it, and hold the event
//  loop for the whole session — every pipeline event lands here, updates live
//  state, and mirrors durable turn data into ChatService.
//  Stop: tear the session down; the Start loop ends when the event streams do.
//
//  This uses Granite's shipping `streamingTask`. Duplicate sends are rejected
//  BEFORE they reach Granite by `MaryRuntime.admitVoiceStart`; otherwise a
//  replacement send would cancel the reducer that owns the live session.
//

import MaryAmbient
import MaryVoice
import Foundation
import Granite
import os

extension VoiceService {
    package struct Start: GraniteReducer {
        package typealias Center = VoiceService.Center
        package init() {}

        private static let log = Logger(subsystem: "nyc.rao.mary", category: "voice.session")

        @Relay var chat: ChatService
        @Relay var config: ConfigService

        package func reduce(state: inout Center.State,
                    stream: @escaping (Center.State) -> Void) async {
            // Every production send acquires admission first. Keep it until
            // the event loop and identity-scoped teardown are both finished.
            defer { MaryRuntime.releaseVoiceStart() }
            guard !state.isSessionActive else { return }

            // Standby owns a microphone until the session claims it. Awaited:
            // the wake engine is genuinely DOWN when this returns, so the two
            // captures never overlap.
            guard await MaryRuntime.wakeStandby.sessionWillStart() else {
                Self.log.error("start aborted: standby microphone did not disarm in time")
                mirror(.error("Listening couldn't start because the standby microphone is still stopping."))
                return
            }

            // Taken only after standby has yielded. A timed-out Start must not
            // consume a wake request that a later, successful Start can honor.
            let handoff = MaryRuntime.takeWakeHandoff()

            let transcriber: any VoiceTranscriber
            switch config.state.sttBackend {
            case .apple: transcriber = AppleSpeechTranscriber()
            }

            let pipeline = VoicePipeline(
                config: VoicePipelineConfig(
                    sttBackend: config.state.sttBackend,
                    voice: config.state.voice,
                    vad: config.state.vad,
                    stopListeningAck: config.state.wakeWordEnabled
                        ? "Okay — say \u{201C}Hey Mary\u{201D} when you need me."
                        : "Okay, going quiet."
                ),
                transcriber: transcriber,
                speaker: MaryRuntime.speaker,
                responder: MaryRuntime.brain,
                // CONTINUOUS HEARING RIDES AMBIENTVOICE'S SWITCH, not the STT
                // backend picker. It is not an alternative way to transcribe a
                // turn — the acoustic path still does that — it is the same
                // capability as noticing: she is aware of the room, or she is
                // not. One switch, one story, and `off` means the microphone
                // feeds nothing but the utterance in front of it.
                // CONTINUOUS HEARING IS OFF IN THIS CUT. Its one consumer
                // was the proactive-speech lane — Mary noticing the room and
                // saying something unprompted — which is not here. A
                // transcriber running with nothing reading it is a microphone
                // left on for no reason.
                continuous: nil
            )
            guard let lease = await MaryRuntime.voiceSession.install(pipeline) else {
                // A concurrent Start won the box; ITS loop owns the session
                // lifecycle. Release only OUR claim — the counter keeps
                // standby down while the winner runs.
                //
                // SAID OUT LOUD rather than returned silently: this branch
                // used to be indistinguishable from a dead button, and it is
                // the branch a latched box (see VoiceSessionBox.stop) drove
                // every single time.
                Self.log.notice("start refused: another session owns the pipeline box")
                mirror(.error("Another listening session is already starting."))
                await MaryRuntime.wakeStandby.noteSessionAborted()
                return
            }
            await MaryRuntime.speaker.setStyle(config.state.speechStyle.style)

            // Subscribe before starting so no early event is missed.
            let events = await pipeline.events()

            do {
                try await pipeline.start()
            } catch {
                Self.log.error("microphone failed to start: \(error.localizedDescription)")
                mirror(.error("The microphone couldn't start: \(error.localizedDescription)"))
                await MaryRuntime.voiceSession.stop(lease)
                await MaryRuntime.wakeStandby.noteSessionEnded()
                return
            }

            state.isSessionActive = true
            state.phase = .listening
            stream(state)

            // The wake handoff, honored only now that the session is real:
            // a request rides in as the first turn; a bare wake earns the
            // greeting. Fired, not awaited — primeTurn runs the WHOLE turn,
            // and the event loop below must already be consuming.
            if let handoff {
                if let remainder = handoff.remainder {
                    Task { await pipeline.primeTurn(query: remainder) }
                } else {
                    let line = WakeGreetings.next()
                    Task { await pipeline.speakCannedLine(line) }
                }
            }

            var turnAccumulated = ""
            var isAmending = false
            /// The turn every in-turn write below belongs to. Without it a
            /// write resolves through "the last unstamped streaming
            /// assistant", which in the .exchangeSuperseded → .turnBegan
            /// window is the NEW turn's bubble.
            var currentTurnID: UUID?

            sessionEvents: for await event in events {
                guard !Task.isCancelled else { break sessionEvents }
                switch event {
                case .stateChanged(let pipelineState):
                    let mapped = phase(for: pipelineState)
                    // While the user revises a superseded query, the chip
                    // stays "revising" through capture and transcription.
                    if isAmending, mapped == .hearingYou || mapped == .transcribing {
                        state.phase = .amending
                    } else {
                        state.phase = mapped
                    }
                    if case .listening(utteranceActive: false) = pipelineState {
                        state.lastPartial = ""
                        isAmending = false
                    }
                    stream(state)

                case .audioLevel(let level):
                    state.audioLevel = level
                    stream(state)

                case .partialTranscript(let partial):
                    state.lastPartial = partial
                    stream(state)

                case .finalTranscript(let text):
                    await MaryRuntime.spokenTurnBegan()
                    turnAccumulated = ""
                    state.lastPartial = ""
                    stream(state)
                    mirror(.userSpoke(text))

                case .heardSpeech:
                    break

                case .continuousUnavailable(let reason):
                    // Said out loud rather than logged: the acoustic path
                    // keeps working, so the only other symptom is that she
                    // never remembers anything — which reads as a broken
                    // engine instead of an absent on-device model.
                    state.lastPartial = "Continuous hearing unavailable — \(reason)"
                    stream(state)

                case .turnBegan(let id):
                    currentTurnID = id
                    mirror(.turnBegan(id))

                case .routineDetached(let id):
                    mirror(.routineDetached(id))

                case .exchangeSuperseded(let id):
                    // The brain removed that exchange; its accumulation is
                    // dead text. Left standing, the next token of ANY turn
                    // re-mirrors the removed turn's whole passage — the
                    // late-append with a fresh coat of paint.
                    turnAccumulated = ""
                    currentTurnID = nil
                    mirror(.exchangeSuperseded(userTurnID: id))

                case .brainToken(let token):
                    turnAccumulated += token
                    // Guarded AT THE WRITE, as TextTurnRunner's `forward`
                    // already was: this loop suspends (spokenSkillUsed, the
                    // mirror hop) and can resume after the session was torn
                    // down or the turn abandoned. An unguarded write paints a
                    // dead turn's text onto whatever bubble is live now.
                    guard !Task.isCancelled else { break sessionEvents }
                    mirror(.assistantText(accumulated: turnAccumulated, turnID: currentTurnID))

                case .skillInvocation(let reference, let argumentsJSON, let runID):
                    await MaryRuntime.spokenSkillUsed()
                    guard !Task.isCancelled else { break sessionEvents }
                    mirror(.abilityBadge(reference, turnID: currentTurnID))
                    mirror(.abilityRunStarted(
                        .requested(
                            id: runID,
                            action: BehavioralAction(
                                intention: reference.invocationName,
                                argumentsJSON: argumentsJSON,
                                skill: reference)),
                        turnID: currentTurnID))

                case .contribution(let json):
                    guard !Task.isCancelled else { break sessionEvents }
                    mirror(.contribution(json: json, turnID: currentTurnID))

                case .autoMemoryTriggered:
                    mirror(.autoMemoryTriggered)

                case .assistantReply(let fullText):
                    mirror(.assistantDone(fullText, turnID: currentTurnID))

                case .turnSuperseded:
                    isAmending = true
                    state.phase = .amending
                    stream(state)
                    mirror(.turnSuperseded)

                case .amendedTranscript(let text):
                    await MaryRuntime.spokenTurnBegan()
                    isAmending = false
                    turnAccumulated = ""
                    state.lastPartial = ""
                    stream(state)
                    mirror(.userAmended(text))

                case .turnCancelled:
                    isAmending = false
                    // Barge-in / follow-up preemption: this turn is over with
                    // no replacement. Its accumulation must not survive to
                    // prefix the next one.
                    turnAccumulated = ""
                    currentTurnID = nil
                    mirror(.turnCancelled)

                case .stopListeningCommand(let transcript, let ack):
                    // The exchange is documented in the transcript — why the
                    // session ended, in her own words — and the mic is already
                    // down with the ack fully drained, so finishing the stop
                    // is all that's left.
                    mirror(.userSpoke(transcript))
                    mirror(.assistantDone(ack, turnID: nil))
                    Task { await MaryRuntime.voiceSession.stop(lease) }

                case .error(let message):
                    mirror(.error(message))

                case .skillResult(let record):
                    guard !Task.isCancelled else { break sessionEvents }
                    mirror(.abilityRunResult(record: record, turnID: currentTurnID))

                case .vad, .ttsChunkStarted, .ttsFinished:
                    break
                }
            }

            // Event streams normally end when the session stops. If Granite
            // cancels this task unexpectedly, identity-scoped teardown is the
            // defensive tail: it cannot touch a later owner's pipeline.
            await MaryRuntime.voiceSession.stop(lease)
            state = .init()
            stream(state)
            // THE release point: every session end — Stop button, "stop
            // listening", pipeline death — finishes the streams and lands
            // here, long after any ack audio drained.
            await MaryRuntime.wakeStandby.noteSessionEnded()
        }

        private func phase(for pipelineState: VoicePipelineState) -> VoicePhase {
            switch pipelineState {
            case .idle: return .idle
            case .listening(let utteranceActive): return utteranceActive ? .hearingYou : .listening
            case .transcribing: return .transcribing
            case .thinking: return .thinking
            case .speaking: return .speaking
            }
        }

        private func mirror(_ kind: ChatService.MirrorVoice.Meta.Kind) {
            chat.center.mirrorVoice.send(ChatService.MirrorVoice.Meta(kind: kind))
        }

        package var behavior: GraniteReducerBehavior {
            .streamingTask(.userInitiated)
        }
    }

    package struct Stop: GraniteReducer {
        package typealias Center = VoiceService.Center
        package init() {}

        package func reduce(state: inout Center.State) {
            Task { await MaryRuntime.voiceSession.stop() }
            // The Start loop resets state when the event streams finish.
        }
    }
}

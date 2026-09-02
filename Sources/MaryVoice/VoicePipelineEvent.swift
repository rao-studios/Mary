//
//  VoicePipelineEvent.swift
//  MaryVoice
//
//  WHAT: Tap stream of every observable moment in the voice loop.
//  IN:   VoicePipeline.emit / LanguageResponder / ProactiveEvent
//  OUT:  UI meter, transcript, barge-in, BrainEvent, ambient deposit
//        (multicast via VoicePipeline.events())
//

import MaryFoundation
import Foundation

/// Where the conversational loop currently is. Consumer: UI / state observers.
public enum VoicePipelineState: Sendable, Equatable {
    case idle
    /// Mic is open. `utteranceActive` is true once VAD has heard speech start.
    case listening(utteranceActive: Bool)
    /// Utterance closed; waiting on the transcriber's final text.
    case transcribing
    /// Transcript sent to the language responder; no audio yet.
    case thinking
    /// Kokoro is speaking the reply (mic stays open for barge-in).
    case speaking
}

/// Voice-activity transitions from the VAD stage. Consumer: UI + barge-in/amend.
public enum VADEvent: Sendable, Equatable {
    case speechStart
    case speechEnd(duration: TimeInterval)
}

/// The tap stream: one event per observable moment in the loop.
public enum VoicePipelineEvent: Sendable {
    /// Loop phase. Consumer: UI / VoicePipelineState observers.
    case stateChanged(VoicePipelineState)
    /// ~30 Hz RMS of the mic, 0…1. Consumer: UI meter.
    case audioLevel(Float)
    /// VAD onset/end. Consumer: UI + barge-in/amend governors.
    case vad(VADEvent)
    /// Live partial transcript mid-utterance. Consumer: transcript bubble.
    case partialTranscript(String)
    /// Utterance became a turn. Consumer: transcript + Brain via `submitTurn`.
    case finalTranscript(String)
    /// Room speech that is not a turn. Consumers deposit to ambient; they must
    /// not treat this as `finalTranscript` (that starts a Brain turn).
    case heardSpeech(String)
    /// Continuous hearing could not start (model / locale / auth). Consumer: UI
    /// status — the acoustic path still works.
    case continuousUnavailable(String)
    /// Streamed token from the language responder. Consumer: transcript.
    case brainToken(String)
    /// Skill ask on the wire (`runID` = one model call). Consumer: transcript chip.
    /// Answer is `skillResult` (`BehavioralActionRecord`).
    case skillInvocation(reference: AbilitySkillReference, argumentsJSON: String, runID: String)
    /// Skill answer. Consumer: transcript chip + execution log.
    case skillResult(record: BehavioralActionRecord)
    /// Mary's own pre-reads for this turn, drained once before the lane
    /// spawned — never a model call. Consumer: the "looked first" capsule.
    case ownReads([BehavioralActionRecord])
    /// Opaque provenance JSON. Consumer: app contribution model.
    case contribution(json: String)
    /// Responder's full final text. Consumer: transcript.
    case assistantReply(String)
    /// Conversation folded into memory. Consumer: collapse transcript.
    case autoMemoryTriggered
    /// Sentence batch entered Kokoro playback. Consumer: UI / TTS status.
    case ttsChunkStarted(String)
    /// Playback drained. Consumer: UI; pipeline re-arms listening.
    case ttsFinished
    /// Thinking-phase speech superseded the turn. Consumer: amend flow / UI.
    case turnSuperseded
    /// Joined original + correction. Consumer: replaces `finalTranscript` on the bubble.
    case amendedTranscript(String)
    /// Turn cancelled with no replacement (barge-in). Consumer: finalize bubble.
    case turnCancelled
    /// First event of every turn — exchange id. Consumer: transcript / follow-up merge.
    case turnBegan(UUID)
    /// Lane detached into a routine. Consumer: keep this bubble as the routine's home.
    case routineDetached(UUID)
    /// Brain dropped an in-flight exchange. Consumer: remove those bubbles by id.
    case exchangeSuperseded(userTurnID: UUID)
    /// Deterministic "stop listening". Mic is already down; ack has drained.
    /// Consumer: `voiceSession.stop()`.
    case stopListeningCommand(transcript: String, ack: String)
    case error(String)
}

// MARK: - The brain seam

/// App plug-in: transcript → `BrainEvent` stream. MaryVoice does not import Frigate.
public protocol LanguageResponder: Sendable {
    func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error>
    /// Amend flow: cancel the in-flight turn, replace its exchange, answer that.
    /// Default: plain `respond` (no history surgery).
    func respondSuperseding(_ userText: String) -> AsyncThrowingStream<BrainEvent, Error>
    /// Cancel the in-flight turn (barge-in). Keep partial text in history.
    func cancel() async
    /// A `.routineProgress` line was dropped (room not quiet). Consumer: delivery
    /// ledger in MaryBrain. Default no-op for probes/tests.
    func noteProgressDropped(_ line: String) async
    /// Unprompted utterance reached its ear verdict (spoke / held / dropped).
    /// Consumer: ambient delivery ledger via `AmbientVoiceDelivery` (MaryFoundation).
    func noteAmbientDelivery(_ delivery: AmbientVoiceDelivery, for candidateID: UUID) async
    /// Detached-routine progress + follow-up utterances. Default: empty stream.
    func proactiveEvents() -> AsyncStream<ProactiveEvent>
}

public extension LanguageResponder {
    func respondSuperseding(_ userText: String) -> AsyncThrowingStream<BrainEvent, Error> {
        respond(to: userText)
    }

    func proactiveEvents() -> AsyncStream<ProactiveEvent> {
        AsyncStream { $0.finish() }
    }

    func noteProgressDropped(_ line: String) async {}

    func noteAmbientDelivery(_ delivery: AmbientVoiceDelivery, for candidateID: UUID) async {}
}

/// Brain events outside any turn. Every case carries the user-turn id that spawned
/// the routine (nil origin = standalone notice). Consumer: transcript + VoicePipeline.
public enum ProactiveEvent: Sendable {
    /// Lane detached into background work. Consumer: status bar (which routines).
    case routineStarted(routineID: UUID, label: String, originUserTurnID: UUID)
    case skillInvocation(
        reference: AbilitySkillReference,
        argumentsJSON: String,
        runID: String,
        originUserTurnID: UUID)
    /// Routine action settled. Consumer: episode that started it, not the open turn.
    case skillResult(record: BehavioralActionRecord, originUserTurnID: UUID)
    case followUpToken(String, originUserTurnID: UUID?)
    case followUpCompleted(fullText: String, originUserTurnID: UUID?)
    case routineCancelled(routineID: UUID, acknowledgement: String, originUserTurnID: UUID)
    /// Lane still running; a droppable progress line. Consumer: VoicePipeline
    /// (`speakRoutineProgress`) — never preempt, never a follow-up, never the ledger
    /// unless dropped (`noteProgressDropped`).
    case routineProgress(String, originUserTurnID: UUID)
    /// Quiet completion. Consumer: UI clears "still working"; nothing is spoken.
    case routineSettled(routineID: UUID, originUserTurnID: UUID)
    /// Unprompted remark (no user turn). Consumer: VoicePipeline (`speakAmbientUtterance`)
    /// — yielding only; never cancel a live turn. `candidateID` joins the ambient trace.
    case ambientUtterance(String, candidateID: UUID)
    /// Memory fold during a routine follow-up. Consumer: collapse transcript (whole page).
    case autoMemoryTriggered
}

/// Who is producing the audio for the turn's reply.
public enum SpeechSource: Sendable, Equatable {
    /// Pipeline synthesizes locally from streamed tokens (default).
    case local
    /// Responder streams server PCM via `.audioChunk`; tokens are transcript-only.
    case server
}

/// Events a `LanguageResponder` emits while answering one turn.
public enum BrainEvent: Sendable {
    /// First event of every turn — exchange id. Consumer: transcript / follow-up merge.
    case turnBegan(id: UUID)
    /// Lane detached (before `.completed`). Consumer: keep this bubble as the routine's home.
    case routineDetached(originUserTurnID: UUID)
    /// In-flight exchange removed (before `.turnBegan`). Consumer: drop those bubbles.
    /// Never emitted for voice amend (`respondSuperseding`).
    case exchangeSuperseded(userTurnID: UUID)
    case token(String)
    /// Skill ask on the wire (`runID` = one model call). Consumer: transcript chip.
    case skillInvocation(reference: AbilitySkillReference, argumentsJSON: String, runID: String)
    /// Skill answer. Consumer: transcript chip + execution log.
    case skillResult(record: BehavioralActionRecord)
    /// Mary's own pre-reads for this turn, drained once before the lane
    /// spawned — never a model call, so never `.skillInvocation`/`.skillResult`.
    /// Consumer: the "looked first" capsule.
    case ownReads([BehavioralActionRecord])
    /// Opaque provenance JSON before `.completed`. Consumer: `VoicePipelineEvent.contribution`.
    case contribution(json: String)
    case completed(fullText: String)
    /// History collapsed to the final exchange. Consumer: collapse transcript. After `.completed`.
    case autoMemoryTriggered
    /// Mid-turn voice switch. `.server` before first realtime event; `.local` re-baselines
    /// so only post-switch text is spoken. Consumer: SpeechRouter.
    case speechSource(SpeechSource)
    /// Server-synthesized float32 LE mono PCM. Only while source is `.server`. Consumer: SpeechRouter.
    case audioChunk(pcm: Data, sampleRate: Double)
    /// Retract everything yielded so far from the ear; what follows replaces it.
    /// Transcript stays. Consumer: SpeechRouter (`softStop`, not `feed`'s baseline reset).
    case retractSpeech
}

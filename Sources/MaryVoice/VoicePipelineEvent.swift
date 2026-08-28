//
//  VoicePipelineEvent.swift
//  MaryVoice
//
//  Every stage of the voice loop reports here. The pipeline multicasts these
//  through `VoicePipeline.events()`, so any number of observers — the app's UI,
//  the probe CLI, tests — can watch voice enter the system, become words,
//  become a reply, and become sound.
//

import MaryFoundation
import Foundation

/// Where the conversational loop currently is.
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

/// Voice-activity transitions from the VAD stage.
public enum VADEvent: Sendable, Equatable {
    case speechStart
    case speechEnd(duration: TimeInterval)
}

/// The tap stream: one event per observable moment in the loop.
public enum VoicePipelineEvent: Sendable {
    case stateChanged(VoicePipelineState)
    /// ~30 Hz RMS level of the mic input, 0…1. Drives level meters.
    case audioLevel(Float)
    case vad(VADEvent)
    /// Live partial transcript, as the recognizer revises it mid-utterance.
    case partialTranscript(String)
    case finalTranscript(String)
    /// SOMETHING SAID IN THE ROOM THAT WAS NOT FOR HER — the continuous
    /// transcript's deposit, carried out as an event because MaryVoice
    /// cannot name the ambient store.
    ///
    /// Deliberately NOT `finalTranscript`: that one means "this became a
    /// turn", and every consumer treats it that way. Heard speech becomes a
    /// memory and nothing else.
    case heardSpeech(String)
    /// Continuous hearing could not start — a missing on-device model, an
    /// unsupported locale, a denied authorization.
    ///
    /// SURFACED RATHER THAN LOGGED because the failure is otherwise invisible:
    /// the acoustic path keeps working perfectly, so the only symptom is that
    /// she never remembers anything, which reads as a bug in the engine
    /// instead of an absent model.
    case continuousUnavailable(String)
    /// A streamed token from the language responder.
    case brainToken(String)
    /// `runID` is the model-wire invocation id — one per CALL, so the UI can
    /// correlate this chip's arguments with the result that answers it.
    ///
    /// THE ASK AND THE ANSWER ARE SHAPED DIFFERENTLY ON PURPOSE. At ask time
    /// there is no target: nothing has been touched yet, so the invocation
    /// carries only what was requested. The answer carries a whole
    /// `BehavioralActionRecord` — the same value the dataset row, the chip and
    /// the execution log are all rendered from, so a result cannot mean one
    /// thing in the transcript and another in the log.
    case skillInvocation(reference: AbilitySkillReference, argumentsJSON: String, runID: String)
    case skillResult(record: BehavioralActionRecord)
    /// Provenance metadata for the reply (opaque JSON — MaryVoice stays
    /// domain-free; the app decodes it into its contribution model).
    case contribution(json: String)
    /// The responder's full final text for the turn.
    case assistantReply(String)
    /// The conversation was folded into memory — collapse the transcript to
    /// the final exchange (mirrors the responder's own history truncation).
    case autoMemoryTriggered
    /// A sentence batch has entered Kokoro playback.
    case ttsChunkStarted(String)
    case ttsFinished
    /// Sustained speech during thinking superseded the in-flight turn; a
    /// correction utterance is now being captured (amend flow).
    case turnSuperseded
    /// Replaces the superseded turn's finalTranscript: the original query and
    /// the correction, deterministically joined.
    case amendedTranscript(String)
    /// A turn was cancelled with no replacement (acoustic/manual barge-in) —
    /// the app should finalize the interrupted transcript bubble.
    case turnCancelled
    /// First event of every turn: the id that anchors this exchange in
    /// history, on the transcript, and on every later follow-up merge.
    case turnBegan(UUID)
    /// The turn's lane detached into a routine: the transcript must keep
    /// this turn's bubble alive as the routine's home.
    case routineDetached(UUID)
    /// The brain superseded an in-flight exchange on behalf of this turn
    /// (a voice request landing while a text turn streamed) — the app
    /// removes that exchange's bubbles, keyed by the removed turn's id.
    case exchangeSuperseded(userTurnID: UUID)
    /// The user said "stop listening" — intercepted deterministically before
    /// the responder ever saw it. The mic is ALREADY DOWN and the spoken ack
    /// has FULLY DRAINED by the time this is emitted, so the consumer's only
    /// job is to finish the session (`voiceSession.stop()`) — and anything it
    /// re-arms afterwards can never overhear the ack's own wake phrase.
    case stopListeningCommand(transcript: String, ack: String)
    case error(String)
}

// MARK: - The brain seam

/// What the app plugs into the pipeline to turn a transcript into a reply.
/// MaryVoice deliberately knows nothing about Frigate or remote endpoints —
/// the app implements this with whichever inference engine is selected.
public protocol LanguageResponder: Sendable {
    func respond(to userText: String) -> AsyncThrowingStream<BrainEvent, Error>
    /// Amend flow: cancel the in-flight turn, REPLACE its exchange with the
    /// amended text, and answer that instead. Default falls back to a plain
    /// respond (no history surgery).
    func respondSuperseding(_ userText: String) -> AsyncThrowingStream<BrainEvent, Error>
    /// Cancel the in-flight turn (barge-in). Implementations should keep any
    /// partial text in their history so the conversation stays coherent.
    func cancel() async
    /// A `.routineProgress` line reached the pipeline and was DROPPED rather
    /// than spoken — the room was not quiet, and the user's decision is that
    /// the mark is worth hearing in the pause it describes and worth nothing
    /// fifteen seconds later.
    ///
    /// THE FAILURE THIS MAKES VISIBLE: `speakRoutineProgress` is a hard,
    /// silent, one-shot gate. Each mark fires exactly once, so a mark dropped
    /// because the user happened to be mid-utterance is consumed FOREVER — no
    /// retry, no trace, and a stalled turn that loses both marks can be silent
    /// from 0 to 420 s with nothing anywhere recording that two spoken
    /// promises were destroyed. Keeping the timing was the decision; keeping
    /// the silence unrecorded was not.
    ///
    /// Defaulted to a no-op so a responder that has no ledger (the probes,
    /// the test doubles) is unaffected.
    func noteProgressDropped(_ line: String) async
    /// An unprompted utterance reached its verdict AT THE EAR — spoken, held,
    /// or dropped because the room never went quiet.
    ///
    /// REPORTED THROUGH THE RESPONDER for the same reason
    /// `noteProgressDropped` is: the decision is the pipeline's, and the
    /// ledger that wants it lives in a package MaryVoice cannot import.
    /// This package depends on MaryFoundation alone, so `AmbientVoiceDelivery`
    /// is a MaryFoundation type and the seam is one defaulted method rather
    /// than a dependency.
    ///
    /// Defaulted to a no-op so a responder with no trace — the probes, the
    /// test doubles — is unaffected.
    func noteAmbientDelivery(_ delivery: AmbientVoiceDelivery, for candidateID: UUID) async
    /// Detached-routine progress + follow-up utterances. Default: an
    /// immediately-finished stream (responders without routines).
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

/// Brain-initiated events OUTSIDE any turn: a detached routine's progress and
/// the grounded spoken follow-up when it finishes. The turn's BrainEvent
/// stream completes when the reply ends; these arrive on their own channel.
/// Every case carries the id of the USER turn that spawned the routine —
/// the anchor that keeps transcript chips and follow-ups on the ORIGINATING
/// exchange instead of whatever bubble is positionally last. `followUpToken`
/// and `followUpCompleted` take an optional: nil marks a STANDALONE notice
/// with no originating routine (the coding bridge, until the app threads
/// its session's origin id through).
public enum ProactiveEvent: Sendable {
    /// A LANE DETACHED AND IS NOW BACKGROUND WORK.
    ///
    /// It carries the routine's own id and its spoken label as well as the
    /// origin, because the status bar's "5 running" was an integer with
    /// nothing behind it: no way to see WHICH five, and no way to stop one.
    /// The registry has held a `label` per routine all along — "still working
    /// on the Purpose section" — and nothing ever showed it.
    case routineStarted(routineID: UUID, label: String, originUserTurnID: UUID)
    case skillInvocation(
        reference: AbilitySkillReference,
        argumentsJSON: String,
        runID: String,
        originUserTurnID: UUID)
    /// A routine's action, settled. Carries the record rather than a summary
    /// for the same reason the turn's does — and the origin id besides,
    /// because a detached routine's records append to the episode that
    /// STARTED it, not to whatever turn happens to be open when it lands.
    case skillResult(record: BehavioralActionRecord, originUserTurnID: UUID)
    case followUpToken(String, originUserTurnID: UUID?)
    case followUpCompleted(fullText: String, originUserTurnID: UUID?)
    case routineCancelled(routineID: UUID, acknowledgement: String, originUserTurnID: UUID)
    /// THE LANE IS STILL RUNNING AND SAYS SO — a wall clock on work that had
    /// none. Not a result, not an answer, and deliberately NOT a follow-up.
    ///
    /// THE FAILURE THIS FIXES (confirmed against a live user session): "pulling
    /// up the Purpose section now…" and then five full minutes of silence,
    /// ending in a script error. Nothing below the lane was announcing itself
    /// and nothing above it was counting, so the only signal the user had that
    /// anything was alive was the chip. The worst case is far past the 420 s
    /// watchdog. The user's decision, verbatim: "Speak progress at ~45 s, keep
    /// working."
    ///
    /// A SEPARATE CASE RATHER THAN `followUpToken`, and each of the three
    /// reasons is a rule already written in this tree:
    /// - it would PREEMPT a live turn. `VoicePipeline`'s follow-up arm calls
    ///   `preemptTurnForFollowUp` for a fresh origin, cancelling whatever the
    ///   user is being answered right now. A progress line must outrank
    ///   nothing at all.
    /// - it would STICK. `FollowUpComposer` commits a completed follow-up per
    ///   origin and the real answer then STACKS underneath it, so "Still
    ///   working…" would stand in the transcript forever above the result it
    ///   was waiting for.
    /// - it would CHURN THE LEDGER. `ReadDeliveryLedger` is a last-value box
    ///   answering "where did the read I just watched go?"; a progress line
    ///   booking a row there overwrites the answer to that question with a
    ///   statement that no read happened.
    ///
    /// Consumers must treat it as droppable: it is worth hearing IN the pause
    /// it describes and worth nothing fifteen seconds later.
    ///
    /// A DROP IS NOT THE SAME AS A DELIVERY, and only one of the two touches
    /// the ledger. A mark that SPEAKS books nothing — it is not a read, and the
    /// churn argument above stands unchanged. A mark that is DROPPED books a
    /// row through `LanguageResponder.noteProgressDropped`, because the drop is
    /// a SILENCE, and a silence nobody records is the exact blind spot the
    /// ledger was written to close. See that method.
    case routineProgress(String, originUserTurnID: UUID)
    /// Terminal, quiet completion: the routine ended with nothing to report
    /// (a no-outcome lane, or the watchdog expired a hung one). UI clears
    /// its "still working" state; nothing is spoken.
    case routineSettled(routineID: UUID, originUserTurnID: UUID)
    /// SHE SPOKE WITHOUT BEING ASKED — the first case in this enum that
    /// traces back to no user turn at all. Every other one is downstream of
    /// something the user said; this one is downstream of the room.
    ///
    /// A SEPARATE CASE RATHER THAN `followUpCompleted(origin: nil)`, and each
    /// of the three reasons is the same rule `routineProgress` above is
    /// carved out for:
    /// - IT WOULD PREEMPT. A nil origin is never stale
    ///   (`VoicePipeline.isStaleFollowUpOrigin`), so the follow-up arm reaches
    ///   `preemptTurnForFollowUp` and CANCELS whatever the user is being
    ///   answered right now. `FollowUpPreemptionTests
    ///   .midGenerationFollowUpCancelsTheTurn` pins that with a nil origin,
    ///   deliberately — it is the coding bridge's contract, not an accident.
    ///   An unprompted remark must outrank NOTHING.
    /// - IT WOULD BE INDISTINGUISHABLE. The coding bridge already owns the
    ///   nil-origin standalone notice. Two producers on one case means the
    ///   trace cannot say which one spoke, and the trace is the point.
    /// - IT WOULD CHURN THE LEDGER. `ReadDeliveryLedger` is a last-value box
    ///   answering "where did the read I just watched go?". A remark is not a
    ///   read, and its verdicts need history rather than a last value —
    ///   "why has she said nothing for ten minutes?" is a question about
    ///   forty candidates, not one.
    ///
    /// SINGLE-SHOT, not a token stream. Nobody is waiting on this, so there is
    /// no first-token latency to buy, and one event means one arm per consumer
    /// instead of the buffer/origin bookkeeping `followUpToken` needs.
    ///
    /// `candidateID` is the JOIN KEY: the id of the row the engine already
    /// booked in its trace, and how the arm that finally decides — quiet,
    /// held, dropped — writes the outcome back onto the candidate that caused
    /// it. The same join `AmbientTraceRecord.exchangeID` does for routes.
    ///
    /// Consumers must treat it as YIELDING: it may be held for a quiet room,
    /// it may be dropped when that never comes, and it may never, ever cancel
    /// a live turn.
    case ambientUtterance(String, candidateID: UUID)
    /// Seer folded the conversation into a long-term memory DURING a detached
    /// routine's follow-up, so the transcript collapses to the final exchange
    /// exactly as it does on the turn-side path.
    ///
    /// It needs its own proactive case because the routine follow-up outlives
    /// the turn whose `BrainEvent` stream carried `.autoMemoryTriggered` — by
    /// the time the flag arrives that continuation has finished, and this is
    /// the only channel still open. Carries no origin id: the collapse is a
    /// whole-page operation, not an anchored write.
    case autoMemoryTriggered
}

/// Who is producing the audio for the turn's reply.
public enum SpeechSource: Sendable, Equatable {
    /// The pipeline synthesizes speech locally from streamed tokens (default).
    case local
    /// The responder streams server-synthesized PCM via `.audioChunk`;
    /// tokens are transcript-only and must not be fed to the local speaker.
    case server
}

/// Events a `LanguageResponder` emits while answering one turn.
public enum BrainEvent: Sendable {
    /// First event of every turn: the id that anchors this exchange in
    /// history, on the transcript, and on every later follow-up merge.
    case turnBegan(id: UUID)
    /// Emitted on the turn stream (before `.completed`) when the lane
    /// detaches: the transcript must keep this turn's bubble alive as the
    /// routine's home.
    case routineDetached(originUserTurnID: UUID)
    /// The turn began by superseding an IN-FLIGHT turn: that turn's partial
    /// exchange was removed from brain history, and the transcript must
    /// drop the same bubbles — emitted before `.turnBegan` (and any token),
    /// carrying the REMOVED exchange's user-turn id. Never emitted for the
    /// voice amend flow (respondSuperseding), whose UI rewrites bubbles in
    /// place.
    case exchangeSuperseded(userTurnID: UUID)
    case token(String)
    /// `runID` is the model-wire invocation id — one per CALL, so the UI can
    /// correlate this chip's arguments with the result that answers it.
    ///
    /// THE ASK AND THE ANSWER ARE SHAPED DIFFERENTLY ON PURPOSE. At ask time
    /// there is no target: nothing has been touched yet, so the invocation
    /// carries only what was requested. The answer carries a whole
    /// `BehavioralActionRecord` — the same value the dataset row, the chip and
    /// the execution log are all rendered from, so a result cannot mean one
    /// thing in the transcript and another in the log.
    case skillInvocation(reference: AbilitySkillReference, argumentsJSON: String, runID: String)
    case skillResult(record: BehavioralActionRecord)
    /// Provenance metadata for the reply, emitted before `.completed` when
    /// available (opaque JSON — see `VoicePipelineEvent.contribution`).
    case contribution(json: String)
    case completed(fullText: String)
    /// The backend folded the conversation into a long-term memory — the
    /// retained history collapsed to the final exchange; the app should
    /// collapse its visible transcript the same way. Emitted after
    /// `.completed`.
    case autoMemoryTriggered
    /// Switches who voices the reply mid-turn. `.server` is emitted
    /// immediately before the first realtime event; `.local` hands narration
    /// back (fallback, post-lane deterministic prose) and resets the
    /// consumer's speaker-accumulation baseline so only post-switch text is
    /// spoken locally.
    case speechSource(SpeechSource)
    /// One chunk of server-synthesized reply audio: float32 LE mono PCM at
    /// `sampleRate`. Only emitted while the speech source is `.server`.
    case audioChunk(pcm: Data, sampleRate: Double)
    /// THE TAKEOVER: everything yielded so far this turn is RETRACTED from the
    /// voice, and whatever follows REPLACES it. Transcript-neutral — the text
    /// already painted stays painted; only the ear is rewound.
    ///
    /// THE FAILURE THIS FIXES (verbatim, from a live session): "I'm on it, but
    /// I need a quick clarification — do you mean the whole document, or the
    /// Background section?" — spoken while `REPLACE_PASSAGE` had already landed
    /// correctly. And on Apple Music: "it correctly opened Apple Music and
    /// played a song, and then followed up after completing the task as if it
    /// was doing it at the moment."
    ///
    /// A REPLACE ARM BESIDE THREE APPEND ARMS. The brain already reaches around
    /// the voice lane's prose three times — the revision report, the
    /// unrecovered-failure line (whose own comment says it is "appended after
    /// Seer's prose so Lane A's optimistic ack can't stand uncorrected") and
    /// the CONFIRM relay — and every one of them APPENDS, which leaves the
    /// stale promise standing in front of its own correction.
    ///
    /// MIRRORS `.speechSource` DELIBERATELY, because the two consumers that
    /// matter (`VoicePipeline`, `TextTurnRunner`) already switch on that case:
    /// one arm each, one implementation in `SpeechRouter`, and voice and text
    /// are covered together instead of drifting apart.
    ///
    /// THE CONSUMER MUST NOT USE `feed`'s BASELINE-RESET RULE. A non-extending
    /// string sets `lastSeenString` and returns — a SWALLOW, not a
    /// substitution: `rawBuffer` still holds the old text, so the new line is
    /// silent AND the stale one still speaks at flush. `softStop()` is the
    /// primitive that actually retracts.
    case retractSpeech
}

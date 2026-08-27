//
//  TextTurnRunner.swift
//  Mary
//
//  The text-mode turn driver — successor to the SendText streaming reducer.
//  A Granite streaming reducer holds a boot/turn-scoped snapshot of the whole
//  state and republishes it per emit (and a second send CANCELS the in-flight
//  one, stranding isGenerating — the stuck-turn defect), so text turns now
//  run as a plain actor loop that forwards BrainEvents into the single sync
//  writer (MirrorVoice). Overlap is a SUPERSEDE, not a drop: the new request
//  cancels the current run, removes its partial exchange from chat AND
//  history together, and answers the new text.
//

import MaryBrain
import MaryVoice
import Foundation
import os

package actor TextTurnRunner {
    package static let shared = TextTurnRunner()

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "chat.text")

    private var current: Task<Void, Never>?
    /// Identity of the current run — the finished task clears itself only if
    /// a superseding submit hasn't already replaced it.
    private var currentToken: UUID?
    /// Set the moment the current run observes .completed. A completed run
    /// whose task hasn't cleared itself yet is NOT in flight: treating it as
    /// one would drive respondSuperseding and delete a FINISHED exchange
    /// from history while chat keeps it. The composer's isBusy gate can't
    /// reach that window, but the Ability Runs undo path submits ungated.
    private var currentCompleted = false
    /// The text turn currently allowed to mutate the shared speaker. This is
    /// independent of `current`: model generation ends before its final TTS
    /// drain, so clearing `current` must not let an old detached
    /// `SpeechRouter.finish()` flush into the next turn.
    private var speakerOwnerToken: UUID?

    package func submit(
        _ text: String,
        mirror: @escaping @Sendable (ChatService.MirrorVoice.Meta.Kind) -> Void
    ) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Cross-mode guard: a live voice session owns the brain and the
        // speaker (single-driver rule); the UI already disables send — a
        // stray path (Ability Runs undo) drops with a log instead of racing
        // the pipeline.
        guard await MaryRuntime.voiceSession.current() == nil else {
            Self.log.warning("typed turn dropped — a voice session is live")
            return
        }

        let superseding = current != nil && !currentCompleted
        // Claim audio BEFORE the first await below. A prior run's detached
        // router finisher may be poised to resume; invalidating its owner now
        // prevents it from flushing after the new turn has reset the shared
        // speaker.
        let token = UUID()
        currentToken = token
        speakerOwnerToken = token
        currentCompleted = false
        current?.cancel()
        // Every accepted user request is a speech barge-in, not only a model
        // supersede. The old condition excluded a response once it had emitted
        // `.completed`, even though that response (or a detached follow-up)
        // could still be audibly draining for seconds. This hard-stops the
        // shared speaker and revokes queued detached-follow-up leases as one
        // floor handoff.
        guard let speakerLease = await FollowUpSpeech.shared.beginUserTurn() else {
            // The only expected rejection is a voice session that claimed
            // the floor between the UI guard above and this actor hop. Do not
            // paint a text exchange whose TTS writer will be silently refused.
            guard currentToken == token, speakerOwnerToken == token else { return }
            current = nil
            currentToken = nil
            currentCompleted = false
            speakerOwnerToken = nil
            Self.log.warning("typed turn dropped — the voice floor won while sending")
            return
        }
        // `beginUserTurn` deliberately awaits the speaker's hard stop. Actor
        // reentrancy means another submit may claim a newer token while this
        // one is suspended. Do not resurrect this stale request by installing
        // its task after the newer turn has already started.
        guard currentToken == token, speakerOwnerToken == token else { return }
        // A voice session can claim after `beginUserTurn` returned but before
        // this actor resumes. The speaker remains the authority, so check its
        // lease once more and abandon rather than opening a non-speaking text
        // turn. Re-check our token after the actor hop for the same reason.
        guard await MaryRuntime.speaker.ownsFloor(speakerLease) else {
            guard currentToken == token, speakerOwnerToken == token else { return }
            current = nil
            currentToken = nil
            currentCompleted = false
            speakerOwnerToken = nil
            Self.log.warning("typed turn dropped — the voice floor claimed during handoff")
            return
        }
        guard currentToken == token, speakerOwnerToken == token else { return }
        if superseding {
            // Chat drops the partial exchange now; respondSuperseding's
            // removeLastExchange drops the same exchange from history —
            // the two views move together.
            mirror(.textSuperseded)
        }
        mirror(.userSpoke(text))

        current = Task {
            await Self.drive(
                text: text,
                superseding: superseding,
                mirror: mirror,
                speakerLease: speakerLease,
                onCompleted: { await self.noteCompleted(token: token) },
                ownsSpeaker: { await self.ownsSpeaker(token: token) },
                releaseSpeaker: { await self.releaseSpeaker(token: token) })
            self.finish(token: token)
        }
    }

    /// Is a typed turn still in flight? Half of text mode's "the room is
    /// quiet" — a follow-up must not take the floor while a reply is still
    /// being generated, even in the gap between two spoken chunks. A run that
    /// has already observed `.completed` is not in flight: its audio is the
    /// speaker's business, and `isSpeaking` covers that half.
    package func isRunning() -> Bool {
        current != nil && !currentCompleted
    }

    private func finish(token: UUID) {
        guard currentToken == token else { return }
        current = nil
        currentToken = nil
        currentCompleted = false
    }

    private func noteCompleted(token: UUID) {
        guard currentToken == token else { return }
        currentCompleted = true
    }

    private func ownsSpeaker(token: UUID) -> Bool {
        speakerOwnerToken == token
    }

    private func releaseSpeaker(token: UUID) {
        guard speakerOwnerToken == token else { return }
        speakerOwnerToken = nil
    }

    /// The turn loop SendText had, minus the state snapshot: every event
    /// forwards to the mirror in arrival order; the speaker rides along so
    /// typed chat is spoken aloud too.
    private static func drive(
        text: String,
        superseding: Bool,
        mirror: @escaping @Sendable (ChatService.MirrorVoice.Meta.Kind) -> Void,
        speakerLease: UUID,
        onCompleted: @escaping @Sendable () async -> Void,
        ownsSpeaker: @escaping @Sendable () async -> Bool,
        releaseSpeaker: @escaping @Sendable () async -> Void
    ) async {
        let speaker = MaryRuntime.speaker
        await speaker.setStyle(MaryRuntime.styleSelection.style)

        // Every forward re-checks cancellation AT THE CALL: an event body
        // can suspend (router, spokenSkillUsed) and resume after a
        // superseding submit cancelled this run — an unguarded late mirror
        // would land a stale chip on the NEW turn's bubble via activeTurnID
        // resolution. A forward that passes this check enqueued on main
        // BEFORE the superseder's own mirrors (cancel happens-before them),
        // so at worst it applies to the old bubble and is swept by
        // .textSuperseded — never the new one.
        let forward: @Sendable (ChatService.MirrorVoice.Meta.Kind) -> Void = { kind in
            guard !Task.isCancelled else { return }
            mirror(kind)
        }

        var accumulated = ""
        var lastSpeechSource: SpeechSource?
        var fullText = ""
        var sawCompleted = false
        /// This run's identity, stamped onto every in-turn write so the
        /// transcript resolves it by id instead of by "whatever streaming
        /// bubble is last" — see TranscriptOps.inTurnAssistantIndex.
        var turnID: UUID?
        // Realtime turns: the server voices the reply (PCM chunks feed the
        // speaker directly); tokens only paint the bubble. The router owns
        // that routing — same machine as VoicePipeline.
        var router = SpeechRouter(speaker: speaker, speakerLease: speakerLease)
        do {
            let events = superseding
                ? MaryRuntime.brain.respondSuperseding(text)
                : MaryRuntime.brain.respond(to: text)
            for try await event in events {
                if Task.isCancelled { break }
                switch event {
                case .turnBegan(let id):
                    turnID = id
                    // WHICH EXCHANGE IS ON SCREEN. Text mode's answer to the
                    // pipeline's `currentUserTurnID`: without it a late
                    // follow-up has nothing to be stale against and cuts into
                    // whatever is speaking. Same id the brain stamps onto
                    // `originUserTurnID`, so the comparison is exact.
                    await FollowUpSpeech.shared.noteUserTurn(id, lease: speakerLease)
                    forward(.turnBegan(id))
                case .token(let token):
                    accumulated += token
                    forward(.assistantText(accumulated: accumulated, turnID: turnID))
                    // `forward` guards the mirror; the SPEAKER needed the same
                    // guard and never had it. consumeToken suspends on the
                    // shared speaker, and a superseding submit can land inside
                    // that suspension — resuming afterwards feeds a
                    // length-offset suffix of THIS turn's passage into the new
                    // turn's live stream.
                    guard !Task.isCancelled, await ownsSpeaker() else { continue }
                    await router.consumeToken(accumulated: accumulated)
                case .speechSource(let source):
                    // A MID-TURN server→local swap is an audible character
                    // change (realtime's continuous render → per-chunk
                    // classic) — it must not be a mystery. Same episodic
                    // channel as the Seer voice degrade notices.
                    if lastSpeechSource == .server, source == .local {
                        MaryRuntime.onVoiceDegrade?(
                            "Seer's realtime voice dropped for this reply — finishing with the standard voice.")
                    }
                    lastSpeechSource = source
                    router.consumeSpeechSource(source, accumulated: accumulated)
                case .retractSpeech:
                    // THE TAKEOVER, in text mode. One arm, because the routing
                    // machine is shared: a typed turn is spoken aloud too, so a
                    // stale acknowledgement is exactly as wrong here as it is
                    // over the mic. Guarded at the call like `.token` — a
                    // superseded run must not soft-stop the shared speaker out
                    // from under the turn that replaced it. The bubble keeps
                    // its text; only the ear is rewound.
                    guard !Task.isCancelled, await ownsSpeaker() else { continue }
                    await router.consumeRetractSpeech(accumulated: accumulated)
                case .audioChunk(let pcm, let sampleRate):
                    guard !Task.isCancelled, await ownsSpeaker() else { continue }
                    await router.consumeAudioChunk(pcm, sampleRate: sampleRate)
                case .skillInvocation(let reference, let argumentsJSON, let runID):
                    await MaryRuntime.spokenSkillUsed()
                    forward(.abilityBadge(reference, turnID: turnID))
                    forward(.abilityRunStarted(
                        .requested(
                            id: runID,
                            action: BehavioralAction(
                                intention: reference.invocationName,
                                argumentsJSON: argumentsJSON,
                                skill: reference)),
                        turnID: turnID))
                case .skillResult(let record):
                    // THE WHOLE RECORD, not four loose fields. The chip, the
                    // execution log and the dataset row are then rendered
                    // from one value — they cannot disagree about what
                    // happened, because there is nothing to keep in step.
                    // The raw machine summary lives on the run row (the chip
                    // modal), never in the chat body.
                    forward(.abilityRunResult(record: record, turnID: turnID))
                case .contribution(let json):
                    forward(.contribution(json: json, turnID: turnID))
                case .routineDetached(let origin):
                    forward(.routineDetached(origin))
                case .exchangeSuperseded(let id):
                    // This turn superseded an in-flight exchange (a stray
                    // overlap the runner didn't drive itself): mirror the
                    // keyed removal, and stop the superseded turn's audio
                    // still draining through the shared speaker.
                    forward(.exchangeSuperseded(userTurnID: id))
                    guard !Task.isCancelled, await ownsSpeaker() else { continue }
                    _ = await speaker.hardStop(lease: speakerLease)
                case .completed(let terminal):
                    // Held for the end — the mirror's assistantDone applies
                    // the D2 rule (an empty terminal never wipes streamed
                    // text).
                    fullText = terminal
                    sawCompleted = true
                    await onCompleted()
                case .autoMemoryTriggered:
                    forward(.autoMemoryTriggered)
                }
            }
            // A cancelled run exits silently — the superseding submit
            // already cleaned up its exchange and owns the page now.
            guard !Task.isCancelled else { return }
            // A stream that ended with neither .completed nor a thrown error
            // was superseded BRAIN-SIDE (a voice turn overlapped this text
            // turn): its .exchangeSuperseded already dropped this turn's
            // bubbles and the superseding flow owns the page — a final
            // assistantDone here would clobber the new turn's bookkeeping.
            // Every legitimate completion yields .completed, so this gate is
            // mechanical, not heuristic.
            guard sawCompleted else { return }
            forward(.assistantDone(fullText, turnID: turnID))
        } catch {
            guard !Task.isCancelled else { return }
            forward(.error(error.localizedDescription))
        }

        // Speak the remainder without holding the loop open for playback —
        // but ONLY if this run still owns the floor. `SpeechRouter.finish()`
        // calls `speaker.flush()`, which speaks `sentenceBatch + rawBuffer`
        // and clears the diff baseline. Unconditional, it sat BELOW every
        // cancellation guard above it, so a superseded run flushed its
        // leftovers into the middle of the new turn's reply and corrupted
        // the baseline behind it. A cancelled run neither feeds nor flushes
        // the shared speaker.
        guard !Task.isCancelled else { return }
        let finishedRouter = router
        Task {
            // The model task intentionally finishes before playback drains.
            // That means this task can begin after a later user request has
            // already claimed the speaker. Do not let an old `flush()` reach
            // the new stream in that case.
            guard await ownsSpeaker() else { return }
            await finishedRouter.finish()
            // `finish()` is conditional at the speaker and may have lost to
            // a newer user/follow-up floor while it drained. Releasing is
            // conditional too, so this old finalizer cannot clear that newer
            // owner.
            _ = await speaker.releaseFloor(speakerLease)
            await releaseSpeaker()
        }
    }
}

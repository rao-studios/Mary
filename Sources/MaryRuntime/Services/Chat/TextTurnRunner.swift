//
//  TextTurnRunner.swift
//  MaryRuntime
//
//  WHAT: Text-mode turn driver — actor loop, not a Granite streaming reducer.
//  OUT:  BrainEvents → ChatService.MirrorVoice
//  PIN:  Overlap is a supersede: cancel current, drop partial exchange from
//        chat AND history, answer the new text.
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
    /// True once this run observed .completed. Completed-but-not-cleared is not in-flight.
    private var currentCompleted = false
    /// Text turn allowed to mutate the speaker. Independent of `current` (TTS may still drain).
    private var speakerOwnerToken: UUID?

    package func submit(
        _ text: String,
        mirror: @escaping @Sendable (ChatService.MirrorVoice.Meta.Kind) -> Void
    ) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Voice session owns brain + speaker. Stray path drops with a log.
        guard await MaryRuntime.voiceSession.current() == nil else {
            Self.log.warning("typed turn dropped — a voice session is live")
            return
        }

        let superseding = current != nil && !currentCompleted
        // Claim audio before the first await — invalidate a poised router finisher.
        let token = UUID()
        currentToken = token
        speakerOwnerToken = token
        currentCompleted = false
        current?.cancel()
        // Every accepted request is barge-in. Hard-stop speaker, revoke detached leases.
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
        // beginUserTurn awaits hard stop. Do not install this task if a newer token won.
        guard currentToken == token, speakerOwnerToken == token else { return }
        // Re-check speaker lease and token after the actor hop.
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

    /// Typed turn still generating? Completed run is not in-flight — audio is isSpeaking.
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

        // Re-check cancellation at each forward — late mirror must not hit the new bubble.
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
                    // Exchange on screen — text-mode currentUserTurnID. Same id as originUserTurnID.
                    await FollowUpSpeech.shared.noteUserTurn(id, lease: speakerLease)
                    forward(.turnBegan(id))
                case .token(let token):
                    accumulated += token
                    forward(.assistantText(accumulated: accumulated, turnID: turnID))
                    // Guard the speaker the same way as forward — consumeToken suspends.
                    guard !Task.isCancelled, await ownsSpeaker() else { continue }
                    await router.consumeToken(accumulated: accumulated)
                case .speechSource(let source):
                    // Mid-turn server→local swap — same notice channel as Seer voice degrade.
                    if lastSpeechSource == .server, source == .local {
                        MaryRuntime.onVoiceDegrade?(
                            "Seer's realtime voice dropped for this reply — finishing with the standard voice.")
                    }
                    lastSpeechSource = source
                    router.consumeSpeechSource(source, accumulated: accumulated)
                case .retractSpeech:
                    // Takeover. Guarded like .token — superseded run must not soft-stop the new speaker.
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
                    // Whole BehavioralActionRecord — chip, log, dataset share one value.
                    forward(.abilityRunResult(record: record, turnID: turnID))
                case .ownReads(let records):
                    forward(.ownReads(records, turnID: turnID))
                case .contribution(let json):
                    forward(.contribution(json: json, turnID: turnID))
                case .routineDetached(let origin):
                    forward(.routineDetached(origin))
                case .exchangeSuperseded(let id):
                    // Stray overlap: drop the keyed exchange, stop its draining audio.
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
            // No .completed and no throw → brain-side supersede. Do not assistantDone.
            guard sawCompleted else { return }
            forward(.assistantDone(fullText, turnID: turnID))
        } catch {
            guard !Task.isCancelled else { return }
            forward(.error(error.localizedDescription))
        }

        // Flush remainder only if this run still owns the floor.
        guard !Task.isCancelled else { return }
        let finishedRouter = router
        Task {
            // Model finishes before playback drains — do not flush if a newer request owns the speaker.
            guard await ownsSpeaker() else { return }
            await finishedRouter.finish()
            // Release only if finish() still owned the floor.
            _ = await speaker.releaseFloor(speakerLease)
            await releaseSpeaker()
        }
    }
}

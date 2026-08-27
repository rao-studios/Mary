//
//  ProactiveBridge.swift
//  Mary
//
//  The proactive channel's app-side consumer — successor to the FollowUps
//  streaming reducer, which held a BOOT-era snapshot of the whole state and
//  republished it on every event (the history-rollback bug). Now a plain
//  loop: detached-routine progress and follow-ups map to id-anchored Kinds
//  and funnel into the single sync writer. Voice playback stays the
//  pipeline's job (single-driver rule); this bridge speaks a follow-up only
//  when no voice session is live.
//
//  Started once from HomeSessionView's boot; the loop lives for the app.
//

import MaryBrain
import MaryVoice
import Foundation

/// Composes each origin's follow-up narration for the transcript: tokens
/// accumulate per origin (interleaved routines no longer garble each other —
/// the old single open/accumulated pair did), and sequential routines on one
/// bubble stack paragraphs with "\n\n", mirroring the brain's
/// mergeFollowUpIntoHistory join so both views read identically.
package struct FollowUpComposer {
    /// Per-origin finalized narration — earlier routines' paragraphs.
    private var committed: [UUID: String] = [:]
    /// Per-origin in-flight accumulation.
    private var open: [UUID: String] = [:]
    /// The standalone notice's accumulation (no origin — each notice is its
    /// own bubble, so nothing stacks).
    private var openNotice = ""

    package init() {}

    package mutating func token(_ token: String, origin: UUID?) -> String {
        guard let origin else {
            openNotice += token
            return openNotice
        }
        let accumulated = (open[origin] ?? "") + token
        open[origin] = accumulated
        return joined(committed[origin], accumulated)
    }

    package mutating func completed(_ fullText: String, origin: UUID?) -> String {
        guard let origin else {
            let text = fullText.isEmpty ? openNotice : fullText
            openNotice = ""
            return text
        }
        let streamed = open.removeValue(forKey: origin) ?? ""
        let final = fullText.isEmpty ? streamed : fullText
        // TWO ROUTINES SAYING THE SAME SENTENCE STACK AS ONE. Identical
        // machine paragraphs repeated under one origin were the live leak's
        // most visible shape; a repeat adds nothing a reader needs.
        if let existing = committed[origin],
           existing.components(separatedBy: "\n\n").contains(final) {
            return existing
        }
        let result = joined(committed[origin], final)
        if !result.isEmpty { committed[origin] = result }
        return result
    }

    /// A CANCELLED routine's in-flight accumulation is dead text: the stop
    /// turn already spoke its acknowledgement, and nothing will ever
    /// `complete` it. Left in `open`, the next routine for the same origin
    /// starts its narration with half of the stopped one's — the late-append
    /// in the transcript, stacked rather than spliced. Only `open` clears:
    /// `committed` holds earlier routines' FINISHED paragraphs, which the
    /// user has already read and which history keeps.
    package mutating func cancelled(origin: UUID) {
        open[origin] = nil
    }

    private func joined(_ committed: String?, _ tail: String) -> String {
        guard let committed, !committed.isEmpty else { return tail }
        guard !tail.isEmpty else { return committed }
        return committed + "\n\n" + tail
    }
}

package enum ProactiveBridge {
    /// The one live subscription. SwiftUI re-runs `.task` on every window
    /// (re)appearance — a second loop would double every chip count and
    /// speak every follow-up twice. MainActor-guarded: start is only ever
    /// called from view boot.
    @MainActor private static var live: Task<Void, Never>?

    /// Subscribe to the brain's proactive channel and forward every event to
    /// the single writer as an id-anchored Kind. Idempotent — a repeat call
    /// returns the existing loop.
    @discardableResult
    @MainActor
    package static func start(
        mirror: @escaping @Sendable (ChatService.MirrorVoice.Meta.Kind) -> Void
    ) -> Task<Void, Never> {
        if let live { return live }
        let task = Task {
            var composer = FollowUpComposer()
            for await event in MaryRuntime.brain.proactiveEvents() {
                switch event {
                case .routineStarted(let origin):
                    mirror(.routineStarted(originTurnID: origin))

                case .skillInvocation(let reference, let argumentsJSON, let runID, let origin):
                    // Progress chip onto the routine's ORIGINATING bubble.
                    mirror(.proactiveAbilityBadge(reference: reference, turnID: origin))
                    mirror(.abilityRunStarted(
                        .requested(
                            id: runID,
                            action: BehavioralAction(
                                intention: reference.invocationName,
                                argumentsJSON: argumentsJSON,
                                skill: reference)),
                        turnID: origin))

                case .skillResult(let record, let origin):
                    // The raw machine summary lives on the run row (the chip
                    // modal) — settled routines no longer narrate it.
                    mirror(.abilityRunResult(record: record, turnID: origin))

                case .followUpToken(let token, let origin):
                    mirror(.followUpChanged(
                        turnID: origin,
                        text: composer.token(token, origin: origin),
                        isFinal: false))

                case .followUpCompleted(let fullText, let origin):
                    mirror(.followUpChanged(
                        turnID: origin,
                        text: composer.completed(fullText, origin: origin),
                        isFinal: true))
                    // Text mode speaks here; a live voice session already
                    // played it through the pipeline.
                    //
                    // THROUGH THE FLOOR, never straight at the speaker. What
                    // stood here was a bare `Task` that `softStop`ped whatever
                    // was speaking and fed the follow-up — with `origin` in
                    // hand and unread. That is how a calendar answer ended up
                    // "glued onto a later reply", and being detached it had no
                    // ordering against a second follow-up either. See
                    // `FollowUpSpeech` for the rule and the reasoning.
                    //
                    // AWAITED, not spawned: `enqueue` only installs a link in
                    // the chain and returns, so the loop keeps pumping — but
                    // two `Task { … }` hops would arrive at the actor in
                    // whichever order the scheduler chose, throwing away the
                    // arrival ordering the brain's own follow-up chain works
                    // to produce.
                    if !fullText.isEmpty {
                        await FollowUpSpeech.shared.enqueue(fullText, origin: origin)
                    }

                case .routineProgress(let line, let origin):
                    // NON-FINAL AND UNCOMMITTED, deliberately. It bypasses
                    // `composer` entirely — nothing accumulates, nothing is
                    // committed — and `applyFollowUpChanged` SETS
                    // `followUpText` rather than appending to it, so the real
                    // answer's own `followUpChanged` overwrites the notice
                    // wholesale instead of stacking a paragraph under it. That
                    // is the whole reason this is not a `followUpToken`: a
                    // committed "Still working…" would stand above its own
                    // result forever. No new transcript Kind is needed for the
                    // same reason.
                    mirror(.followUpChanged(turnID: origin, text: line, isFinal: false))
                    // Text mode speaks it through the SAME floor every other
                    // late utterance uses — on the quiet arm only, with cut-in
                    // disallowed and no ledger row (see `FollowUpSpeech
                    // .Delivery.progress`). A live voice session ignores this:
                    // the pipeline plays its own.
                    await FollowUpSpeech.shared.enqueue(line, origin: origin, as: .progress)

                case .routineCancelled(_, let origin):
                    // The stop turn already spoke and mirrored its ack —
                    // this is chip + origin bookkeeping only. The partial
                    // narration dies with the routine (see `cancelled`).
                    composer.cancelled(origin: origin)
                    mirror(.routineEnded(originTurnID: origin))

                case .routineSettled(let origin):
                    // One routine fully done (speech included — settle fires
                    // after the serialized follow-up).
                    mirror(.routineEnded(originTurnID: origin))

                case .ambientUtterance(let line, let candidateID):
                    // ITS OWN TRAILING BUBBLE, never someone else's. The
                    // standalone-notice path in `applyFollowUpChanged` keeps
                    // one row by id and releases it on `isFinal`, so each
                    // remark lands as a fresh bubble instead of accumulating
                    // into the coding bridge's notice.
                    //
                    // Deliberately NOT through `composer`: that accumulates
                    // per origin, and every nil-origin producer shares one
                    // accumulator — a remark and a coding failure arriving
                    // together would paint into each other.
                    mirror(.followUpChanged(turnID: nil, text: line, isFinal: true))
                    await FollowUpSpeech.shared.enqueue(
                        line, origin: nil, as: .ambient(candidateID))

                case .autoMemoryTriggered:
                    // Seer folded the conversation while a detached routine
                    // was narrating. The page collapses through the SAME Kind
                    // the turn-side path uses, so both routes end in one
                    // `collapseToFinalExchange`.
                    mirror(.autoMemoryTriggered)
                }
            }
        }
        live = task
        return task
    }
}

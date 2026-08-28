//
//  TranscriptOps.swift
//  Mary
//
//  The single writer's mutation bodies, pure and unit-testable: every
//  conversation write — voice, text, and proactive — funnels through
//  MirrorVoice into `apply`. The doctrine here is id-resolution: in-turn
//  writes target the ACTIVE turn's bubble, deferred writes target the
//  ORIGINATING turn's bubble, and an unknown id drops with a log — never
//  a positional fallback (positional attachment was the mis-anchored-chip
//  and stolen-follow-up bug).
//

import MaryBrain
import Foundation
import os

package enum TranscriptOps {

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "chat.anchor")

    package static func apply(_ kind: ChatService.MirrorVoice.Meta.Kind,
                      to state: inout ChatService.Center.State) {
        switch kind {
        case .userSpoke(let text):
            state.appendExchange(userText: text)

        case .turnBegan(let id):
            // Stamp the trailing exchange — from the last user row to the
            // end — so chat and history agree on the turn's identity. The
            // amend flow reuses its rows; restamping keeps them under the
            // NEW turn's id, exactly as the brain's history does. Standalone
            // notices are NOT this turn's rows: the open one (tracked id)
            // and any finalized unstamped assistant narrate other work —
            // stamping them would hand them to the new turn's in-turn
            // writes to clobber.
            state.activeTurnID = id
            if let lastUser = state.conversation.utterances.lastIndex(where: { $0.role == .user }) {
                for idx in lastUser..<state.conversation.utterances.endIndex {
                    let row = state.conversation.utterances[idx]
                    if row.id == state.standaloneNoticeID { continue }
                    if row.role == .assistant, row.turnID == nil, !row.isStreaming { continue }
                    state.conversation.utterances[idx].turnID = id
                }
            }

        case .assistantText(let accumulated, let turnID):
            guard let idx = inTurnAssistantIndex(state, turnID: turnID) else { return }
            state.conversation.utterances[idx].isThinking = false
            state.conversation.utterances[idx].text = accumulated

        case .abilityBadge(let reference, let turnID):
            guard let idx = inTurnAssistantIndex(state, turnID: turnID) else { return }
            state.conversation.utterances[idx].isThinking = false
            if !state.conversation.utterances[idx].abilityBadges.contains(reference) {
                state.conversation.utterances[idx].abilityBadges.append(reference)
            }

        case .abilityRunStarted(let run, let turnID):
            // One row per CALL — unlike the badge above, runs never dedupe.
            // Anchored the same way (proactive producers pass the origin id).
            let idx = turnID.flatMap { bubbleIndex(turnID: $0, in: state) }
                ?? inTurnAssistantIndex(state, turnID: nil)
            guard let idx else { return }
            if !state.conversation.utterances[idx].actions.contains(where: { $0.id == run.id }) {
                state.conversation.utterances[idx].actions.append(run)
            }

        case .abilityRunResult(let record, let turnID):
            // The result answers whichever bubble holds the ask — correlated
            // by the wire invocation id, never by position.
            //
            // IT REPLACES THE ROW RATHER THAN PATCHING TWO FIELDS. The ask
            // row was composed from what was REQUESTED; the settled record
            // carries what was TOUCHED — the element, its frame, the adapter
            // trail — and merging by assignment would have kept the ask's
            // empty target forever.
            let idx = turnID.flatMap { bubbleIndex(turnID: $0, in: state) }
                ?? inTurnAssistantIndex(state, turnID: nil)
            guard let idx else { return }
            if let runIdx = state.conversation.utterances[idx].actions
                .firstIndex(where: { $0.id == record.id }) {
                state.conversation.utterances[idx].actions[runIdx] = record
            } else {
                // A RESULT WITH NO ASK still lands. A lane veto refuses
                // before any invocation is announced, and a refusal nobody
                // can see is the transcript disagreeing with what happened.
                state.conversation.utterances[idx].actions.append(record)
            }

        case .contribution(let json, let turnID):
            guard let idx = inTurnAssistantIndex(state, turnID: turnID) else { return }
            state.conversation.utterances[idx].contribution =
                SeerContribution.fromJSON(json)

        case .turnSuperseded:
            // Amend flow: the bubble goes back to thinking; the identity
            // stays until the replacing turn's .turnBegan restamps it.
            guard let idx = currentAssistantIndex(state) else { return }
            state.conversation.utterances[idx].text = ""
            state.conversation.utterances[idx].abilityBadges = []
            // The spans are CHARACTER OFFSETS into the text just cleared.
            // Left behind, they index the replacement reply and paint
            // brushstrokes over words the credited source never wrote.
            state.conversation.utterances[idx].contribution = nil
            state.conversation.utterances[idx].isThinking = true
            state.conversation.utterances[idx].isStreaming = true

        case .userAmended(let text):
            // Rewrite the superseded user line in place — the amended
            // query replaces it rather than appending a second bubble.
            if let userIdx = state.conversation.utterances.lastIndex(where: { $0.role == .user }) {
                state.conversation.utterances[userIdx].text = text
            }
            if let idx = currentAssistantIndex(state) {
                state.conversation.utterances[idx].isThinking = true
                state.conversation.utterances[idx].isStreaming = true
            }
            state.isGenerating = true

        case .turnCancelled:
            if let idx = currentAssistantIndex(state) {
                state.conversation.utterances[idx].isThinking = false
                state.conversation.utterances[idx].isStreaming = false
                if shouldDropHusk(state.conversation.utterances[idx], state: state) {
                    state.conversation.utterances.remove(at: idx)
                }
            }
            state.activeTurnID = nil
            state.isGenerating = false

        case .assistantDone(let fullText, let turnID):
            // A terminal from a producer that knows its turn must resolve to
            // that exact bubble.  In the supersede → turnBegan gap, falling
            // back to the last unstamped streaming bubble would let an old
            // completion finalize the new reply.  A miss is deliberately a
            // no-op: its exchange is gone, and it has no bookkeeping claim on
            // the current turn either.
            guard let idx = inTurnAssistantIndex(state, turnID: turnID) else { return }
            state.conversation.utterances[idx].isThinking = false
            state.conversation.utterances[idx].isStreaming = false
            // Replace text only when the terminal payload genuinely differs;
            // an EMPTY fullText (silent action turn) must never wipe the
            // streamed words the user already read.
            // Contribution spans are safe across this write: Seer yields
            // .contribution and .completed(fullText:) back to back off the
            // SAME spokenText, so replacing the accumulated stream with
            // fullText anchors the offsets to the string they were measured
            // against — it corrects them rather than drifting them.
            if !fullText.isEmpty, fullText != state.conversation.utterances[idx].text {
                state.conversation.utterances[idx].text = fullText
            }
            // A silent action turn ends with empty text: keep the row when
            // chips ran (the badges ARE the reply), when follow-up narration
            // already merged in, or when a live routine still calls this
            // bubble home — drop it only when truly blank and orphaned.
            if shouldDropHusk(state.conversation.utterances[idx], state: state) {
                state.conversation.utterances.remove(at: idx)
            }
            // A tagged terminal may finalize an older retained bubble (for
            // example one hosting a detached routine). It must not clear the
            // newer turn's generation state. Untagged legacy producers retain
            // the existing current-bubble behavior.
            if turnID == nil || state.activeTurnID == turnID {
                state.activeTurnID = nil
                state.isGenerating = false
            }

        case .textSuperseded:
            // A new typed request replaced the in-flight turn: drop its
            // partial exchange — the caller drives respondSuperseding, whose
            // removeLastExchange drops the same exchange from history, so
            // the two views move together. A standalone notice interleaved
            // after the user row is spared (it narrates other work).
            if state.isGenerating,
               let lastUser = state.conversation.utterances.lastIndex(where: { $0.role == .user }) {
                let active = state.activeTurnID
                let noticeID = state.standaloneNoticeID
                let range = lastUser..<state.conversation.utterances.endIndex
                let survivors = state.conversation.utterances[range].filter { row in
                    // A nil active id must not match unstamped rows wholesale
                    // (nil == nil) — in the pre-stamp window the in-flight
                    // rows are exactly the unstamped STREAMING ones; a
                    // finalized notice keeps its place.
                    let inFlight = row.role == .user
                        || (active != nil && row.turnID == active)
                        || (row.turnID == nil && row.isStreaming && row.id != noticeID)
                    return !inFlight
                }
                state.conversation.utterances.replaceSubrange(range, with: survivors)
            }
            state.activeTurnID = nil
            state.isGenerating = false

        case .exchangeSuperseded(let id):
            // Brain-authoritative overlap supersede: the brain removed the
            // exchange keyed by this user-turn id; drop the same bubbles —
            // every row of that exchange (user included) was stamped by its
            // .turnBegan, so the removal is exact and spares proactive
            // rows, standalone notices, and other turns' bubbles. The NEW
            // turn's rows are already on the page (its userSpoke precedes
            // the brain stream) and still unstamped — untouched here, then
            // stamped by the .turnBegan that follows this event. Unlike
            // .textSuperseded, isGenerating stays: the superseding turn's
            // userSpoke owns it and is still streaming.
            state.conversation.utterances.removeAll { $0.turnID == id }
            // The removed turn can no longer be active; until the new
            // .turnBegan lands, in-turn writes resolve via the unstamped
            // streaming row — exactly the new turn's bubble.
            if state.activeTurnID == id { state.activeTurnID = nil }

        case .routineDetached(let origin):
            if !state.activeRoutineOrigins.contains(origin) {
                state.activeRoutineOrigins.append(origin)
            }

        case .routineStarted(let routineID, let label, let origin):
            // A LIST, not a Bool and no longer a bare count: several routines
            // can run at once, one finishing must not douse the chip while
            // another still works, and a person looking at the chip should be
            // able to see which is which.
            //
            // Keyed by id, so a duplicate start is a no-op rather than an
            // inflated count.
            if !state.runningRoutineRows.contains(where: { $0.id == routineID }) {
                state.runningRoutineRows.append(RunningRoutineRow(
                    id: routineID, label: label, originTurnID: origin))
            }
            // Idempotent with .routineDetached — whichever channel lands
            // first registers the origin.
            if !state.activeRoutineOrigins.contains(origin) {
                state.activeRoutineOrigins.append(origin)
            }

        case .routineEnded(let routineID, let origin):
            // REMOVAL BY ID IS IDEMPOTENT, and that is an improvement rather
            // than housekeeping: a cancelled routine can yield both
            // `.routineCancelled` and, moments later, `.routineSettled`. The
            // old counter clamped that double-decrement at zero and quietly
            // lost a still-running sibling's place in the count.
            state.runningRoutineRows.removeAll { $0.id == routineID }
            // Remove ONE occurrence — never the bubble itself.
            if let idx = state.activeRoutineOrigins.firstIndex(of: origin) {
                state.activeRoutineOrigins.remove(at: idx)
            }

        case .proactiveAbilityBadge(let reference, let turnID):
            // Progress chip onto the routine's ORIGINATING bubble. Unknown
            // id → drop + log; a positional fallback would re-open the
            // chip-on-the-wrong-bubble bug this slice closes.
            guard let idx = bubbleIndex(turnID: turnID, in: state) else {
                log.warning("proactive ability badge '\(reference.displayLabel, privacy: .public)' dropped — origin bubble \(turnID) not on the page")
                return
            }
            if !state.conversation.utterances[idx].abilityBadges.contains(reference) {
                state.conversation.utterances[idx].abilityBadges.append(reference)
            }

        case .followUpChanged(let turnID, let text, let isFinal):
            applyFollowUpChanged(turnID: turnID, text: text, isFinal: isFinal, to: &state)

        case .autoMemoryTriggered:
            state.conversation.collapseToFinalExchange()

        case .error(let message):
            if let idx = currentAssistantIndex(state) {
                state.conversation.utterances[idx].isThinking = false
                state.conversation.utterances[idx].isStreaming = false
                if shouldDropHusk(state.conversation.utterances[idx], state: state) {
                    state.conversation.utterances.remove(at: idx)
                }
            }
            state.lastError = message
            state.activeTurnID = nil
            state.isGenerating = false
        }
    }

    // MARK: - Resolution (id first, never position)

    /// The in-flight turn's assistant bubble: the last assistant row stamped
    /// with the active turn id — or, in the pre-stamp window (.userSpoke has
    /// appended the streaming row but .turnBegan hasn't arrived), the last
    /// unstamped streaming assistant.
    static func currentAssistantIndex(_ state: ChatService.Center.State) -> Int? {
        let utterances = state.conversation.utterances
        if let active = state.activeTurnID,
           let idx = utterances.lastIndex(where: { $0.role == .assistant && $0.turnID == active }) {
            return idx
        }
        return utterances.lastIndex(where: {
            $0.role == .assistant && $0.turnID == nil && $0.isStreaming
                && $0.id != state.standaloneNoticeID
        })
    }

    /// An in-turn write's bubble, resolved BY THE WRITE'S OWN IDENTITY.
    ///
    /// `currentAssistantIndex` answers "which bubble is the page's active
    /// turn writing to" — the right question for a write that is definitely
    /// the active turn's. It is the WRONG question for a write that merely
    /// arrived: a superseded turn's token, resuming after `.exchangeSuperseded`
    /// cleared `activeTurnID` and before the new `.turnBegan` stamps, falls
    /// through to "the last unstamped streaming assistant" — the NEW turn's
    /// bubble. That is the reported late-append, in the transcript.
    ///
    /// So: when the producer knows its turn, the write resolves against THAT
    /// id and a miss DROPS + LOGS — the same drop-and-log doctrine follow-ups
    /// and proactive chips already follow. `lastIndex` (not `firstIndex`)
    /// keeps this identical to `currentAssistantIndex`'s stamped branch: the
    /// amend flow can leave more than one assistant row under one id.
    /// A nil id keeps the legacy resolution for producers with no `.turnBegan`
    /// to hand (probes, direct unit writes).
    static func inTurnAssistantIndex(
        _ state: ChatService.Center.State, turnID: UUID?
    ) -> Int? {
        guard let turnID else { return currentAssistantIndex(state) }
        guard let idx = state.conversation.utterances.lastIndex(where: {
            $0.role == .assistant && $0.turnID == turnID
        }) else {
            log.warning("in-turn write dropped — turn \(turnID) has no bubble on the page")
            return nil
        }
        return idx
    }

    /// The assistant bubble anchored to a turn id — deferred writes (chips,
    /// follow-ups) land here regardless of what is positionally last.
    static func bubbleIndex(turnID: UUID, in state: ChatService.Center.State) -> Int? {
        state.conversation.utterances.firstIndex(where: {
            $0.role == .assistant && $0.turnID == turnID
        })
    }

    // MARK: - Private

    /// A bubble earns its place with any of: spoken text, merged follow-up
    /// narration, Ability badges, or a still-running routine that will need it
    /// as a home. Only a row with none of those is a droppable husk.
    private static func shouldDropHusk(
        _ bubble: Utterance, state: ChatService.Center.State
    ) -> Bool {
        bubble.text.isEmpty
            && (bubble.followUpText ?? "").isEmpty
            && bubble.abilityBadges.isEmpty
            && bubble.actions.isEmpty
            && !(bubble.turnID.map { state.activeRoutineOrigins.contains($0) } ?? false)
    }

    private static func applyFollowUpChanged(
        turnID: UUID?, text: String, isFinal: Bool,
        to state: inout ChatService.Center.State
    ) {
        if let turnID {
            // Anchored: merge into the ORIGINATING bubble. Unknown id →
            // drop + log (the audio already spoke; automemory keeps the
            // final exchange, so this only hits routines outliving a
            // collapse of their own turn).
            guard !text.isEmpty else { return }
            guard let idx = bubbleIndex(turnID: turnID, in: state) else {
                log.warning("follow-up dropped — origin bubble \(turnID) not on the page")
                return
            }
            state.conversation.utterances[idx].followUpText = text
            return
        }

        // Standalone notice (no origin — e.g. the coding bridge): maintain
        // ONE trailing assistant row by id — a spoken failure always stays
        // visible, but no existing bubble is ever positionally mutated.
        if let noticeID = state.standaloneNoticeID,
           let idx = state.conversation.utterances.firstIndex(where: { $0.id == noticeID }) {
            if !text.isEmpty {
                state.conversation.utterances[idx].text = text
            }
            state.conversation.utterances[idx].isStreaming = !isFinal
            if isFinal { state.standaloneNoticeID = nil }
            return
        }
        guard !text.isEmpty else { return }
        let notice = Utterance(role: .assistant, text: text, isStreaming: !isFinal)
        state.conversation.utterances.append(notice)
        state.standaloneNoticeID = isFinal ? nil : notice.id
    }
}

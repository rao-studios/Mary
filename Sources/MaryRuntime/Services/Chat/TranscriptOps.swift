//
//  TranscriptOps.swift
//  MaryRuntime
//
//  WHAT: Single writer's mutation bodies — pure, unit-testable.
//  IN:   MirrorVoice → apply
//  PIN:  Id-resolution. In-turn → active bubble; deferred → originating
//        bubble; unknown id drops with a log. Never positional fallback.
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
            // Stamp trailing exchange (last user row → end). Spare standalone notices.
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
            // Replace the row by wire invocation id, never position. Settled record, not a patch.
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
            // Terminal with a turn id resolves to that bubble. Miss is a no-op.
            guard let idx = inTurnAssistantIndex(state, turnID: turnID) else { return }
            state.conversation.utterances[idx].isThinking = false
            state.conversation.utterances[idx].isStreaming = false
            // Replace text only when fullText differs. Empty fullText never wipes streamed words.
            if !fullText.isEmpty, fullText != state.conversation.utterances[idx].text {
                state.conversation.utterances[idx].text = fullText
            }
            // Silent action: keep if chips, follow-up, or live routine; drop only if orphaned.
            if shouldDropHusk(state.conversation.utterances[idx], state: state) {
                state.conversation.utterances.remove(at: idx)
            }
            // Tagged terminal may finalize an older bubble — do not clear the newer turn.
            if turnID == nil || state.activeTurnID == turnID {
                state.activeTurnID = nil
                state.isGenerating = false
            }

        case .textSuperseded:
            // Drop the partial exchange. Spare standalone notices after the user row.
            if state.isGenerating,
               let lastUser = state.conversation.utterances.lastIndex(where: { $0.role == .user }) {
                let active = state.activeTurnID
                let noticeID = state.standaloneNoticeID
                let range = lastUser..<state.conversation.utterances.endIndex
                let survivors = state.conversation.utterances[range].filter { row in
                    // Nil active id must not match unstamped rows (nil == nil). Streaming only.
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
            // Drop bubbles stamped with this user-turn id. New turn's unstamped rows stay.
            // isGenerating stays — superseding userSpoke is still streaming.
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
            // Running-routine list keyed by id. Duplicate start is a no-op.
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
            // Removal by id is idempotent (cancelled then settled).
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

    /// In-flight assistant bubble: last stamped with active turn, or last unstamped streaming.
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

    /// In-turn write resolved by the write's own turn id. Miss drops + logs.
    /// Nil id keeps legacy resolution (probes). lastIndex — amend can leave two rows.
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
            // Merge into the originating bubble. Unknown id → drop + log.
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

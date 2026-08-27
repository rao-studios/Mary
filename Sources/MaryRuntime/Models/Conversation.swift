//
//  Conversation.swift
//  Mary
//
//  The conversation's durable data — the paper Mary and the user write on.
//  Modeled on Gita's Passage: transient stream flags are excluded from
//  persistence so an utterance cut short by an app kill reloads as final text.
//

import MaryBrain
import Foundation
import Granite

package enum UtteranceRole: String, GraniteModel {
    case user
    case assistant
}

/// ONE SKILL CALL'S FULL STORY, attached to the utterance it ran under —
/// the chip modal's data. `id` is the model-wire invocation id, which is
/// what correlates the invocation (arguments) with the result that answers
/// it. Raw machine summaries live HERE now, not in the chat body.
// `AbilityRun` USED TO LIVE HERE — a transcript row with its own id,
// reference, arguments, summary and ok flag, composed at the mirror arms
// while the execution log composed a different row and the dataset a third.
// Up to six disjoint records for one action, no two of which had to agree,
// and two of them demonstrably did not.
//
// `BehavioralActionRecord` is the row now. It is already `Codable` and
// `Hashable`, so it persists as a `GraniteModel` without a projection, and
// the chip, the log and the dataset render the same value.

package struct Utterance: GraniteModel, Identifiable {
    package var id: UUID = .init()
    package var role: UtteranceRole = .assistant
    package var text: String = ""
    /// Frozen Ability/Skill identities invoked by this turn. Package edits or
    /// uninstalls never rewrite the visual history of an earlier exchange.
    package var abilityBadges: [AbilitySkillReference] = []
    var createdAt: Date = .init()
    /// Which totem owners/documents informed this reply, credited down to
    /// character spans (assistant turns in seer mode only). Optional keeps
    /// old persisted conversations decoding.
    package var contribution: SeerContribution? = nil
    /// The brain turn (BrainTurn.id of the user turn) this row belongs to —
    /// the anchor every deferred write resolves by, never position. Optional
    /// keeps old persisted conversations decoding.
    package var turnID: UUID? = nil
    /// Detached-routine narration merged into this bubble (the follow-up's
    /// transcript half). Rendered as appended italic paragraphs; kept
    /// separate from `text` so contribution spans keep indexing the main
    /// body. Optional keeps old persisted conversations decoding.
    package var followUpText: String? = nil
    /// Every skill call this turn made, in call order — the chip modal's
    /// records. Distinct from `abilityBadges` (deduped display identities):
    /// runs accumulate one row per CALL, args and result included. Optional
    /// default keeps old persisted conversations decoding.
    /// WHAT THIS TURN DID — one record per dispatched action, in order.
    package var actions: [BehavioralActionRecord] = []
    /// Transient stream flags — excluded from persistence.
    package var isThinking: Bool = false
    package var isStreaming: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, role, text, abilityBadges, createdAt, contribution, turnID,
             followUpText, actions
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(UtteranceRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        abilityBadges = try container.decode(
            [AbilitySkillReference].self, forKey: .abilityBadges)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        contribution = try container.decodeIfPresent(
            SeerContribution.self, forKey: .contribution)
        turnID = try container.decodeIfPresent(UUID.self, forKey: .turnID)
        followUpText = try container.decodeIfPresent(String.self, forKey: .followUpText)
        // Absent in every conversation persisted before runs existed.
        actions = try container.decodeIfPresent(
            [BehavioralActionRecord].self, forKey: .actions) ?? []
    }

    package init(
        role: UtteranceRole = .assistant, text: String = "",
        isThinking: Bool = false, isStreaming: Bool = false
    ) {
        self.role = role
        self.text = text
        self.isThinking = isThinking
        self.isStreaming = isStreaming
    }
}

package struct Conversation: GraniteModel {
    package var utterances: [Utterance] = []

    package init(utterances: [Utterance] = []) {
        self.utterances = utterances
    }

    /// Automemory collapse (Sis's ChatStream rule): the backend folded the
    /// conversation into a long-term memory, so the page keeps only the final
    /// EXCHANGE — the last user turn through the end, INCLUDING any trailing
    /// or interleaved assistant-only follow-up rows (blindly keeping the last
    /// two rows orphaned a stale reply whenever a proactive bubble broke
    /// alternation). Mirrors the brain's own removeLastExchange shape; no-op
    /// when no user row exists (a proactive-only page).
    package mutating func collapseToFinalExchange() {
        guard let lastUser = utterances.lastIndex(where: { $0.role == .user }),
              lastUser > 0 else { return }
        utterances.removeFirst(lastUser)
    }

    /// The Settings "Context window" limit, applied to the PAGE the same way
    /// `trimHistory` applies it to the brain: drop whole EXCHANGES from the
    /// front — a user row through just before the next user row — until the
    /// visible count fits. Exchange-boundary trimming is what keeps a reply
    /// from outliving the request that earned it; a plain `removeFirst(n)`
    /// would strand answers under no question.
    ///
    /// `protected` holds turn ids whose rows must survive regardless: the
    /// live turn, and the origins of detached routines still running. Every
    /// deferred write resolves by `turnID` (never position), so trimming a
    /// routine's origin out from under it means its follow-up narration
    /// arrives with nowhere to land and is dropped.
    package mutating func trimToRecentMessages(limit: Int, protecting protected: Set<UUID> = []) {
        while visibleCount > limit {
            guard let firstUser = utterances.firstIndex(where: { $0.role == .user })
            else { break }
            // The NEXT user row is the floor to drop down to. Without one
            // there is a single exchange left, and an oversized single
            // exchange is kept whole — dropping "through the end" here would
            // empty the page outright, which is not a window, it is a wipe.
            // Searched in the slice PAST firstUser, so it is always at least
            // firstUser + 1 — the range below can never be empty, and the
            // loop always makes progress.
            guard let dropEnd = utterances[(firstUser + 1)...]
                .firstIndex(where: { $0.role == .user })
            else { break }
            // A protected turn anywhere in the doomed range stops the trim
            // outright rather than skipping ahead — dropping a LATER exchange
            // while keeping an earlier one would reorder the page.
            let holdsProtected = utterances[0..<dropEnd].contains {
                $0.turnID.map(protected.contains) ?? false
            }
            if holdsProtected { break }
            utterances.removeSubrange(0..<dropEnd)
        }
    }

    /// What the page actually renders as a bubble. Mirrors the husk predicate
    /// the boot sweep uses: an assistant row carrying only stream flags is not
    /// a message, but a chip-only or follow-up-only bubble is.
    private var visibleCount: Int {
        utterances.reduce(0) { count, utterance in
            switch utterance.role {
            case .user:
                return count + 1
            case .assistant:
                let isHusk = utterance.text.isEmpty && utterance.abilityBadges.isEmpty
                    && utterance.actions.isEmpty
                    && (utterance.followUpText ?? "").isEmpty
                return isHusk ? count : count + 1
            }
        }
    }
}

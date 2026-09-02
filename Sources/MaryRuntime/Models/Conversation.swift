//
//  Conversation.swift
//  MaryRuntime
//
//  WHAT: Durable conversation page — paper Mary and the user write on.
//  IN:   ChatService.Center (persist: conversation only)
//  OUT:  Utterance, BehavioralActionRecord, SeerContribution
//  PIN:  Stream flags excluded from persistence. Deferred writes resolve by
//        turnID, never position. One BehavioralActionRecord per dispatched act.
//

import MaryBrain
import Foundation
import Granite

package enum UtteranceRole: String, GraniteModel {
    case user
    case assistant
}

package struct Utterance: GraniteModel, Identifiable {
    package var id: UUID = .init()
    package var role: UtteranceRole = .assistant
    package var text: String = ""
    /// Frozen Ability/Skill identities this turn invoked. History is not rewritten.
    package var abilityBadges: [AbilitySkillReference] = []
    var createdAt: Date = .init()
    /// Totem owners/documents that informed this reply (seer-mode assistant).
    package var contribution: SeerContribution? = nil
    /// BrainTurn.id of the user turn — every deferred write resolves by this.
    package var turnID: UUID? = nil
    /// Detached-routine narration merged into this bubble. Separate from `text`
    /// so contribution spans keep indexing the main body.
    package var followUpText: String? = nil
    /// One record per dispatched action, call order. Distinct from abilityBadges.
    package var actions: [BehavioralActionRecord] = []
    /// Mary's own pre-reads this turn — never a model call. Rendered as one
    /// muted "looked first" capsule, never as an Ability|Skill chip.
    package var ownReads: [BehavioralActionRecord] = []
    /// Transient stream flags — excluded from persistence.
    package var isThinking: Bool = false
    package var isStreaming: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, role, text, abilityBadges, createdAt, contribution, turnID,
             followUpText, actions, ownReads
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
        // Absent in conversations persisted before runs existed.
        actions = try container.decodeIfPresent(
            [BehavioralActionRecord].self, forKey: .actions) ?? []
        // Absent in conversations persisted before own-reads existed.
        ownReads = try container.decodeIfPresent(
            [BehavioralActionRecord].self, forKey: .ownReads) ?? []
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

    /// Keep the final exchange (last user row through the end, including
    /// trailing assistant-only follow-ups). Mirrors brain.removeLastExchange.
    package mutating func collapseToFinalExchange() {
        guard let lastUser = utterances.lastIndex(where: { $0.role == .user }),
              lastUser > 0 else { return }
        utterances.removeFirst(lastUser)
    }

    /// Drop whole exchanges from the front until visibleCount fits `limit`.
    /// `protected` turn ids (live turn, live routine origins) stop the trim.
    package mutating func trimToRecentMessages(limit: Int, protecting protected: Set<UUID> = []) {
        while visibleCount > limit {
            guard let firstUser = utterances.firstIndex(where: { $0.role == .user })
            else { break }
            // Next user row is the drop floor. A single oversized exchange is kept whole.
            guard let dropEnd = utterances[(firstUser + 1)...]
                .firstIndex(where: { $0.role == .user })
            else { break }
            // Protected turn in the doomed range stops trim — skipping would reorder.
            let holdsProtected = utterances[0..<dropEnd].contains {
                $0.turnID.map(protected.contains) ?? false
            }
            if holdsProtected { break }
            utterances.removeSubrange(0..<dropEnd)
        }
    }

    /// Bubbles the page renders. Chip-only / follow-up-only rows count; stream husks do not.
    private var visibleCount: Int {
        utterances.reduce(0) { count, utterance in
            switch utterance.role {
            case .user:
                return count + 1
            case .assistant:
                let isHusk = utterance.text.isEmpty && utterance.abilityBadges.isEmpty
                    && utterance.actions.isEmpty && utterance.ownReads.isEmpty
                    && (utterance.followUpText ?? "").isEmpty
                return isHusk ? count : count + 1
            }
        }
    }
}

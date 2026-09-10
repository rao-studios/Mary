//
//  ChatService+Center.swift
//  MaryRuntime
//
//  WHAT: Persisted conversation page + transient turn/routine ids.
//  IN:   Boot / MirrorVoice / SetHistoryLimit / Reset
//  OUT:  Conversation, RunningRoutineRow
//  PIN:  In-turn writes resolve by turnID, never position. Persist key
//        conversation only so Granite cannot re-seed over a decode miss.
//

import Granite
import SwiftUI

extension ChatService {
    package struct Center: GraniteCenter {
        package init() {}
        package struct State: GraniteState {
            package var conversation: Conversation = .init()
            package var isGenerating: Bool = false
            package var lastError: String? = nil
            /// Transient boot status ("warming Mistral…"); nil when ready.
            package var bootStatus: String? = nil
            package var isReady: Bool = false
            /// Detached routines still executing — status chip + popover.
            package var runningRoutineRows: [RunningRoutineRow] = []
            /// Count the status chip already binds.
            package var runningRoutines: Int { runningRoutineRows.count }
            /// In-flight turn id (BrainTurn.id). Stamped .turnBegan; cleared at end.
            package var activeTurnID: UUID? = nil
            /// Live routine origin ids — empty bubble that still runs is its home.
            package var activeRoutineOrigins: [UUID] = []
            /// Streaming standalone-notice bubble (nil-origin proactive follow-up).
            package var standaloneNoticeID: UUID? = nil
            /// Settings "Context window" for the PAGE. Config-sourced; never persist.
            package var messageLimit: Int = 12

            enum CodingKeys: String, CodingKey {
                case conversation
            }

            package init() {}

            /// Missing key must not fail restore — a thrown decode re-seeds defaults.
            package init(from decoder: Decoder) throws {
                self.init()
                let c = try decoder.container(keyedBy: CodingKeys.self)
                conversation = try c.decodeIfPresent(Conversation.self, forKey: .conversation) ?? Conversation()
            }
        }

        @Event package var boot: Boot.Reducer
        @Event package var reset: Reset.Reducer
        @Event package var setReadiness: SetReadiness.Reducer
        @Event package var setHistoryLimit: SetHistoryLimit.Reducer
        @Event package var mirrorVoice: MirrorVoice.Reducer

        @Store(
            persist: "mary.persistence.chat.0001",
            autoSave: true,
            preload: true
        ) public var state: State
    }
}

extension ChatService.Center.State {
    /// Append user text and the empty assistant utterance streaming fills.
    package mutating func appendExchange(userText: String) {
        conversation.utterances.append(
            .init(role: .user, text: userText)
        )
        conversation.utterances.append(
            .init(role: .assistant, isThinking: true, isStreaming: true)
        )
        // After append: window measured against the page about to show. Floor 4.
        conversation.trimToRecentMessages(limit: messageLimit, protecting: protectedTurnIDs)
        isGenerating = true
        lastError = nil
    }

    /// Live turn + every detached routine origin — husk-drop / window floor.
    var protectedTurnIDs: Set<UUID> {
        var ids = Set(activeRoutineOrigins)
        if let activeTurnID { ids.insert(activeTurnID) }
        return ids
    }
}

//
//  ChatService.Boot.swift
//  MaryRuntime
//
//  WHAT: Page boot, context-window install, readiness footer, conversation reset.
//  IN:   ChatService.Center events
//  OUT:  Conversation.trimToRecentMessages, MaryRuntime.brain.clearHistory
//

import Foundation
import Granite

extension ChatService {
    /// Drop empty husks from a mid-stream kill. Stream flags are not persisted
    /// so interrupted text reloads finalized; chip / follow-up rows are not husks.
    package struct Boot: GraniteReducer {
        package typealias Center = ChatService.Center
        package init() {}

        package func reduce(state: inout Center.State) {
            state.conversation.utterances.removeAll {
                $0.text.isEmpty && $0.abilityBadges.isEmpty
                    && $0.actions.isEmpty
                    && ($0.followUpText ?? "").isEmpty && !$0.isStreaming
            }
            state.isGenerating = false
            state.lastError = nil
        }
    }

    /// Settings "Context window" on the PAGE. Same number as brain.setHistoryLimit.
    /// Trim on set is destructive — raising the limit does not restore rows.
    package struct SetHistoryLimit: GraniteReducer {
        package typealias Center = ChatService.Center
        package init() {}

        package struct Meta: GranitePayload {
            package var limit: Int

            package init(limit: Int) {
                self.limit = limit
            }
        }

        @Payload package var meta: Meta?

        package func reduce(state: inout Center.State) {
            guard let meta else { return }
            // Same floor as brain.setHistoryLimit — narrower than one exchange is not a window.
            state.messageLimit = max(4, meta.limit)
            state.conversation.trimToRecentMessages(
                limit: state.messageLimit, protecting: state.protectedTurnIDs)
        }
    }

    /// Boot / engine-switch status on the page footer.
    package struct SetReadiness: GraniteReducer {
        package typealias Center = ChatService.Center
        package init() {}

        package struct Meta: GranitePayload {
            package var status: String?
            package var ready: Bool

            package init(status: String? = nil, ready: Bool) {
                self.status = status
                self.ready = ready
            }
        }

        @Payload package var meta: Meta?

        package func reduce(state: inout Center.State) {
            guard let meta else { return }
            state.bootStatus = meta.status
            state.isReady = meta.ready
        }
    }

    /// Forget the conversation — page and brain both.
    package struct Reset: GraniteReducer {
        package typealias Center = ChatService.Center
        package init() {}

        package func reduce(state: inout Center.State) {
            state.conversation = Conversation()
            state.isGenerating = false
            state.lastError = nil
            Task { await MaryRuntime.brain.clearHistory() }
        }
    }
}

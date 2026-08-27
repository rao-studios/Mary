import Foundation
import Granite

extension ChatService {
    /// Sanitize leftovers from a mid-stream kill. Stream flags aren't
    /// persisted, so an interrupted utterance reloads as finalized text —
    /// only empty husks need dropping (and their orphaned user lines stay,
    /// preserving what the user actually said). A row that carries chips or
    /// merged follow-up narration is NOT a husk: a chip-only silent
    /// delegation bubble must survive relaunch.
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

    /// The Settings "Context window" size, installed on the PAGE. Sent at
    /// boot (once config has restored) and on every stepper change, alongside
    /// the `brain.setHistoryLimit` that governs the model's own window — one
    /// number, two stores, so the label finally describes both.
    ///
    /// Trimming on set is deliberate: dragging the stepper down shortens the
    /// visible page immediately, which is the behaviour the caption promises.
    /// It is destructive, exactly like the brain's own trim — raising the
    /// limit again does not bring anything back.
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
            // Same floor the brain applies in setHistoryLimit — a window
            // narrower than one exchange plus its answer isn't a window.
            state.messageLimit = max(4, meta.limit)
            state.conversation.trimToRecentMessages(
                limit: state.messageLimit, protecting: state.protectedTurnIDs)
        }
    }

    /// Boot/engine-switch status surfaced on the page footer.
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

import Granite
import SwiftUI

extension ChatService {
    package struct Center: GraniteCenter {
        package init() {}
        package struct State: GraniteState {
            package var conversation: Conversation = .init()
            package var isGenerating: Bool = false
            package var lastError: String? = nil
            /// Transient boot status line ("warming Mistral…", nil when ready).
            package var bootStatus: String? = nil
            package var isReady: Bool = false
            /// How many detached routines (Skill work that outlived its turn)
            /// are still executing — transient, drives the "still working"
            /// chip. A count, because several can run at once and one
            /// finishing must not douse the chip for the rest.
            package var runningRoutines: Int = 0
            /// The in-flight turn's identity (BrainTurn.id of its user turn)
            /// — stamped by .turnBegan, cleared at turn end. Transient: every
            /// in-turn transcript write resolves against it, never position.
            package var activeTurnID: UUID? = nil
            /// Origin turn ids of LIVE routines — the husk-drop guard: an
            /// empty bubble whose routine still runs is the routine's home
            /// and must survive turn end. Transient.
            package var activeRoutineOrigins: [UUID] = []
            /// The trailing standalone-notice bubble (a proactive follow-up
            /// with no origin, e.g. the coding bridge) currently streaming —
            /// so its updates target it by id, never position. Transient.
            package var standaloneNoticeID: UUID? = nil
            /// The Settings "Context window" size, governing the PAGE as well
            /// as the brain. Transient and config-sourced: `setHistoryLimit`
            /// installs it at boot and on every stepper change, so it must
            /// never be restored from a stale persisted copy.
            package var messageLimit: Int = 12

            enum CodingKeys: String, CodingKey {
                case conversation
            }

            package init() {}

            /// Tolerant decode: a missing key must NEVER fail the restore —
            /// a thrown decode makes Granite re-seed defaults over the
            /// user's conversation (Gita's rule).
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
    /// Appends the user's words and the empty assistant utterance the
    /// streaming reducer fills in.
    package mutating func appendExchange(userText: String) {
        conversation.utterances.append(
            .init(role: .user, text: userText)
        )
        conversation.utterances.append(
            .init(role: .assistant, isThinking: true, isStreaming: true)
        )
        // AFTER the append, never before: the window has to be measured
        // against the page the user is about to see. Trimming runs from the
        // FRONT, and the floor is 4, so the pair just added is never at risk.
        conversation.trimToRecentMessages(limit: messageLimit, protecting: protectedTurnIDs)
        isGenerating = true
        lastError = nil
    }

    /// Turn ids the rolling window must not drop: the live turn, and every
    /// detached routine's origin. Both already tracked for the husk guard.
    var protectedTurnIDs: Set<UUID> {
        var ids = Set(activeRoutineOrigins)
        if let activeTurnID { ids.insert(activeTurnID) }
        return ids
    }
}

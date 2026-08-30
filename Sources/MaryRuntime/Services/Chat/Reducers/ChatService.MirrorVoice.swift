//
//  ChatService.MirrorVoice.swift
//  MaryRuntime
//
//  WHAT: The conversation writer — voice, text, and proactive funnel here.
//  IN:   VoiceService.Session, TextTurnRunner, ProactiveBridge
//  OUT:  TranscriptOps.apply (pure mutation bodies)
//  PIN:  Single writer. thread = .main; fresh state at commit. Streaming
//        reducers snapshot-and-republish — two of them caused rollback.
//

import MaryBrain
import Foundation
import Granite
import SwiftUI

extension ChatService {
    package struct MirrorVoice: GraniteReducer {
        package typealias Center = ChatService.Center
        package init() {}

        package struct Meta: GranitePayload {
            package enum Kind: Codable {
                case userSpoke(String)
                // In-turn writes carry their turn id. See TranscriptOps.inTurnAssistantIndex.
                case assistantText(accumulated: String, turnID: UUID? = nil)
                case abilityBadge(AbilitySkillReference, turnID: UUID? = nil)
                /// One skill CALL began — args in hand, result pending, so
                /// the record's disposition is `.unsettled`. Correlated to
                /// its result by the wire run id.
                case abilityRunStarted(BehavioralActionRecord, turnID: UUID? = nil)
                /// That call, settled — the SAME id, the whole record.
                case abilityRunResult(record: BehavioralActionRecord, turnID: UUID? = nil)
                case contribution(json: String, turnID: UUID? = nil)
                /// Terminal write is in-turn — late completion drops instead of finalizing the newest.
                case assistantDone(String, turnID: UUID? = nil)
                /// Amend flow: the in-flight turn was superseded; the trailing
                /// assistant bubble goes back to thinking.
                case turnSuperseded
                /// Amend flow: rewrite the last USER bubble with the merged
                /// query (original — correction).
                case userAmended(String)
                /// Barge-in with no replacement: finalize (or drop) the
                /// interrupted assistant bubble so nothing sticks streaming.
                case turnCancelled
                /// Automemory fired: collapse the page to the final exchange.
                case autoMemoryTriggered
                /// The turn's identity — first event of every turn; stamps
                /// the trailing exchange so later writes resolve by id.
                case turnBegan(UUID)
                /// The turn's lane detached: keep its bubble alive as the
                /// routine's home even if the turn ends empty.
                case routineDetached(UUID)
                /// Text supersede: a new typed request replaced the in-flight
                /// turn — drop its partial exchange (history does the same).
                case textSuperseded
                /// Brain removed the partial exchange — drop the same bubbles. UI never guesses.
                case exchangeSuperseded(userTurnID: UUID)
                /// Routine began/ended — running rows + origin. Id and label name the work.
                case routineStarted(routineID: UUID, label: String, originTurnID: UUID)
                case routineEnded(routineID: UUID, originTurnID: UUID)
                /// A detached routine's progress chip, anchored to its
                /// ORIGINATING turn — never the positionally-last bubble.
                case proactiveAbilityBadge(reference: AbilitySkillReference, turnID: UUID)
                /// Follow-up narration for the originating bubble (nil turnID
                /// = standalone notice with no origin, e.g. coding bridge).
                case followUpChanged(turnID: UUID?, text: String, isFinal: Bool)
                case error(String)
            }
            package var kind: Kind

            package init(kind: Kind) {
                self.kind = kind
            }
        }

        @Payload package var meta: Meta?

        package func reduce(state: inout Center.State) {
            guard let meta else { return }
            switch meta.kind {
            case .userSpoke, .autoMemoryTriggered, .textSuperseded, .exchangeSuperseded:
                // Structural changes animate (rows appear/disappear); token
                // paints stay immediate.
                withAnimation {
                    TranscriptOps.apply(meta.kind, to: &state)
                }
            default:
                TranscriptOps.apply(meta.kind, to: &state)
            }
        }

        /// Every commit hops to main and reads fresh state — no interleaved writers.
        package var thread: DispatchQueue? { .main }
    }
}

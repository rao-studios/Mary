//
//  ChatService.MirrorVoice.swift
//  Mary
//
//  THE conversation writer — voice, text, and proactive events all funnel
//  here (single-writer rule). Granite's streaming reducers snapshot state
//  once at task start and republish the whole state per emit — two of them
//  writing this conversation was the rollback bug — so every driver became
//  a plain loop (VoiceService.Session, TextTurnRunner, ProactiveBridge)
//  forwarding events into this one sync reducer. `thread = .main` serializes
//  every commit on the main queue with a fresh state read at commit time.
//  Mutation bodies live in TranscriptOps (pure, unit-tested).
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
                // IN-TURN WRITES CARRY THEIR TURN. Without an id these
                // resolved through "the last unstamped streaming assistant",
                // which — in the .exchangeSuperseded → .turnBegan window — is
                // the NEW turn's bubble: a superseded turn's tokens painting
                // themselves onto the reply that replaced them. The id is
                // optional only because a producer that never saw .turnBegan
                // (probes) still has to write; a producer that HAS the id
                // must pass it. See TranscriptOps.inTurnAssistantIndex.
                case assistantText(accumulated: String, turnID: UUID? = nil)
                case abilityBadge(AbilitySkillReference, turnID: UUID? = nil)
                /// One skill CALL began — args in hand, result pending, so
                /// the record's disposition is `.unsettled`. Correlated to
                /// its result by the wire run id.
                case abilityRunStarted(BehavioralActionRecord, turnID: UUID? = nil)
                /// That call, settled — the SAME id, the whole record.
                case abilityRunResult(record: BehavioralActionRecord, turnID: UUID? = nil)
                case contribution(json: String, turnID: UUID? = nil)
                /// The terminal write is an in-turn mutation just like a
                /// token or Ability badge. It carries its producer's turn so a
                /// late completion can be dropped instead of finalizing the
                /// newest streaming bubble.
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
                /// Brain-authoritative overlap supersede: the brain removed
                /// the partial exchange keyed by this user-turn id — drop
                /// the same bubbles. Removal happens ONLY on this event
                /// (the UI never guesses), so transcript and history agree
                /// by construction.
                case exchangeSuperseded(userTurnID: UUID)
                /// Proactive channel: a routine began / ended (settled AND
                /// cancelled both end) — running rows + origin bookkeeping.
                ///
                /// The routine's own id and label ride along so the status bar
                /// can name the work and offer to stop it; the origin alone
                /// could do neither (several routines can share one origin).
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

        /// The serialization guarantee: every commit hops to the main queue
        /// and reads fresh state there — no interleaved writers, no stale
        /// snapshots. (Sends become async even from main; no call site reads
        /// state immediately after send.)
        package var thread: DispatchQueue? { .main }
    }
}

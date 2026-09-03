//
//  RoutingHabitRecordingContext.swift
//  MaryBrain
//
//  WHAT: WHO may teach the router, and what the habit says.
//  IN:   the lanes that represent a real routing decision
//  OUT:  the grant `AbilityRuntime.dispatch` requires before recording
//  PIN:  Recording lived in the dispatch chokepoint with NO notion of lane, so
//        every dispatch taught the router something — including a `type_at_cursor`
//        whose "utterance" was "yes please", and the runtime's own internal
//        pre-reads. A habit is only worth learning when the words that caused
//        the act are the words being stored.
//
import MaryAmbient
import Foundation
import os

public enum RoutingHabitRecordingContext {

    /// Which road reached the dispatch. The distinction is not bookkeeping:
    /// it decides whether a READ may be learned (see `AbilityRuntime`).
    public enum Lane: Sendable, Equatable {
        /// The embedding picked this Skill uniquely and dispatched with no
        /// model round — recording is pure reinforcement of a win the corpus
        /// already produced from this very query.
        case confidence
        /// The model chose the Skill. The route's own opinion may have been
        /// wrong, which is precisely what makes these worth learning.
        case model
    }

    /// One habit per lane instance. A routine's second and third steps run
    /// under the same utterance; without this they would each map that
    /// utterance onto a Skill the user never named.
    public final class Budget: @unchecked Sendable {
        private let remaining = OSAllocatedUnfairLock<Int>(initialState: 1)

        public init() {}

        public func consume() -> Bool {
            remaining.withLock { left in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
        }
    }

    public struct Grant: Sendable {
        public var lane: Lane
        /// THE WORDS THAT CAUSED THE ACT — the bare utterance, captured where
        /// the lane began. Never `world.store.routingQuery()`: that is the
        /// composed multi-line form (diluted for scoring) and it is
        /// process-wide, so a routine outliving its turn would read the NEXT
        /// turn's query.
        public var query: String
        public var intent: AmbientIntent
        public var budget: Budget

        public init(lane: Lane, query: String, intent: AmbientIntent, budget: Budget = Budget()) {
            self.lane = lane
            self.query = query
            self.intent = intent
            self.budget = budget
        }
    }

    /// Absent means "do not record". Set only by a lane that owns a routing
    /// decision; the runtime's own self-dispatches never see one.
    @TaskLocal public static var grant: Grant?

    /// THE INTENT A DISPATCH ACTUALLY PROVES, or nil for "teach nothing".
    ///
    /// This is the poisoning fix. Recording used the route's PRE-dispatch
    /// intent, so a turn misrouted to `converse` that the model nonetheless
    /// executed stored a `converse` positive — strengthening the very verdict
    /// that had closed the `route.intent == .operate` shortcut gate. The
    /// misclassification taught itself, and nothing ever revisited the label.
    ///
    /// A dispatch is definitionally not conversation: the act is the evidence.
    /// So `converse` maps to `operate` rather than being believed.
    /// `revise`/`halt`/`decide`/`architect` are deterministic or
    /// classifier-owned — the embedding never settles them (see
    /// `SemanticIntentIndex.eligibleIntents`), so seeding them would be corpus
    /// nothing can read.
    public static func recordableIntent(_ route: AmbientIntent?) -> AmbientIntent? {
        switch route {
        case .operate, .compose, .perceive, .ask:
            return route
        case .converse:
            return .operate
        default:
            return nil
        }
    }

    /// The grant for a lane, or nil when this route teaches nothing.
    public static func grant(
        lane: Lane, query: String, route: AmbientIntent?
    ) -> Grant? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let intent = recordableIntent(route)
        else { return nil }
        return Grant(lane: lane, query: query, intent: intent)
    }

    /// Run `body` under `grant`, or plainly when there is nothing to teach.
    public static func withGrant<T>(
        _ grant: Grant?, _ body: () async -> T
    ) async -> T {
        guard let grant else { return await body() }
        return await $grant.withValue(grant) { await body() }
    }
}

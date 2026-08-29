//
//  RetrievalTraceLedger.swift
//  MaryBrain
//
//  WHAT RETRIEVAL WAS ASKED, AND WHAT CAME BACK — one row per exchange,
//  newest first.
//
//  Shaped exactly like `AmbientTraceLog`, which is itself shaped like
//  `AbilityExecutionLog` has already copied that
//  shape a third time: an NSLock-guarded ring buffer, process-wide,
//  in-memory, session-scoped, late-attach mutators that silently drop notes
//  for evicted rows, no callouts under the lock. Copying the blessed shape
//  again is the house pattern, not duplication.
//
//  IT EXISTS BECAUSE THE RETRIEVAL STORY IS INVISIBLE TODAY. The resolved
//  `RetrievalScope` is minted per request inside the two Seer clients, the
//  `requestID` goes out on the wire and is never seen again, and the returned
//  `SeerContribution` is consumed by the highlight UI and dropped. Retrieval
//  is the core of the simulated-cognition paradigm, and it was the one
//  mechanism in this area with no ledger row — "why didn't she remember
//  that?" had no runtime answer. Rows join `AmbientTraceLog` by `exchangeID`,
//  so a route and its retrieval can be read side by side without guessing by
//  position.
//
//  REDACTION IS COMPILE-ENFORCED, not reviewed-for: no field of any record
//  here can carry prose. Ids, labels, scores, counts only. The projection
//  inits are the only way in — `SeerContributionTrace` reduces spans to
//  counts, and `AmbientInjectionTrace`'s sole init takes an
//  `AmbientRendering`, so block text has no field to land in.
//
//  PURELY OBSERVATIONAL: nothing may read this ledger on a decision path.
//

import MaryAmbient
import Foundation

/// Which transport carried the request. Both wrap the identical
/// `ChatRequest`, so the row must say which one actually went out — a scope
/// bug that only shows on one transport is otherwise invisible.
public enum SeerTransportKind: String, Sendable, Equatable {
    case sse
    case realtime
    /// Mary's direct Totem gRPC — Ability lane, not Seer RAG.
    case grpc
}

/// Which of the two per-turn prompts a spend or injection row describes.
public enum PromptLane: String, Sendable, Equatable {
    /// The Skill execution lane's system prompt.
    case system
    /// The voice lane's Seer instructions.
    case seerInstructions
}

/// One request's scope, exactly as it went onto the wire — projected from the
/// same `SeerWire.SeerScope` value the client encodes, so the row can never
/// disagree with the bytes it claims to explain.
public struct SeerRequestTrace: Sendable, Equatable, Identifiable {
    /// The wire join key: `SeerWire.scope`'s minted `requestID` (a lowercased
    /// UUID string). The contribution that comes back belongs to exactly one
    /// of a row's requests, and this is how the pane says which.
    public var id: String
    public var sentAt: Date
    public var transport: SeerTransportKind
    public var ownerID: String
    /// Seer's semantics verbatim: true → all of the owner's documents;
    /// false → only `groups`.
    public var aggregate: Bool
    /// Ids and labels only — the group filter as sent, minus the redundant
    /// per-group owner id (it is always `ownerID` above).
    public var groups: [RetrievalScope.Group]
    /// The `entities` relationship cues, verbatim ids.
    public var relationshipHints: [String]
    public var personalTotemID: String?

    /// THE ONLY WAY IN from a Seer chat request: a trace is a projection of
    /// the scope value the wire encodes, never a hand-assembled claim about
    /// it.
    init(
        scope: SeerWire.SeerScope,
        transport: SeerTransportKind,
        sentAt: Date = Date()
    ) {
        self.id = scope.requestID
        self.sentAt = sentAt
        self.transport = transport
        self.ownerID = scope.ownerID
        self.aggregate = scope.aggregate
        self.groups = (scope.groups ?? []).map {
            RetrievalScope.Group(id: $0.id, label: $0.label)
        }
        self.relationshipHints = scope.entities ?? []
        self.personalTotemID = scope.personalTotemID
    }

    /// Mary's Ability-lane gRPC search. Ids and labels only — the same
    /// redaction rule as the Seer projection.
    public init(
        grpcAbilitySearch ownerID: String,
        groups: [RetrievalScope.Group],
        relationshipHints: [String],
        sentAt: Date = Date()
    ) {
        self.id = UUID().uuidString.lowercased()
        self.sentAt = sentAt
        self.transport = .grpc
        self.ownerID = ownerID
        self.aggregate = false
        self.groups = groups
        self.relationshipHints = relationshipHints
        self.personalTotemID = nil
    }
}

/// What came back: owners, influence and credit — with every character span
/// PROJECTED TO COUNTS. Span arrays index into the spoken reply, so storing
/// them here would be storing a map of prose; the counts answer the pane's
/// question ("how much of the reply did this owner inform?") without it.
public struct SeerContributionTrace: Sendable, Equatable {

    public struct OwnerTrace: Sendable, Equatable, Identifiable {
        /// `SeerContribution.Owner.id` verbatim: ownerID when present, else
        /// the totem id.
        public var id: String
        public var totemID: String
        /// Sorted — `Owner.documentIDs` is a Set, and a row that reorders
        /// itself between reads is a diff the pane cannot trust.
        public var documentIDs: [String]
        /// documentID → influence weight, verbatim scores.
        public var influence: [String: Double]
        public var royalty: Double
        public var earning: Double
        public var spanCount: Int
        /// Sum of span lengths — the credit's size, without its text.
        public var creditedChars: Int
    }

    /// Royalty-descending; equal royalties tie-break on totem id so the
    /// order is deterministic (the source is a Set).
    public var owners: [OwnerTrace]
    public var totalPayout: Double
    public var totalCost: Double
    public var receivedAt: Date

    /// The only init — the projection IS the redaction.
    public init(_ contribution: SeerContribution, receivedAt: Date = Date()) {
        self.owners = contribution.owners
            .map { owner in
                OwnerTrace(
                    id: owner.id,
                    totemID: owner.totemID,
                    documentIDs: owner.documentIDs.sorted(),
                    influence: owner.influence,
                    royalty: owner.royalty,
                    earning: owner.earning,
                    spanCount: owner.spans.count,
                    creditedChars: owner.spans.reduce(0) {
                        $0 + max(0, $1.upper - $1.lower)
                    })
            }
            .sorted {
                $0.royalty == $1.royalty
                    ? $0.totemID < $1.totemID
                    : $0.royalty > $1.royalty
            }
        self.totalPayout = contribution.totalPayout
        self.totalCost = contribution.totalCost
        self.receivedAt = receivedAt
    }
}

/// What the ambient store actually injected into one lane's prompt — mode,
/// keys and sizes, never the rendered text.
public struct AmbientInjectionTrace: Sendable, Equatable {
    public var lane: PromptLane
    /// Which branch of the user's three-way rule ordered the facts.
    public var mode: AmbientRankingMode
    /// `AmbientRendering.keys` verbatim: the keys behind blocks AND mentions,
    /// in rendered order — so "was this fact even offered?" is answerable per
    /// row, not just "how many were".
    public var keys: [AmbientKey]
    public var blockCount: Int
    public var mentionCount: Int
    /// TIER 0 lines injected — the surfaces spend before any detail, so a
    /// waterfall that omitted them would misattribute the budget.
    public var surfaceCount: Int
    /// Characters the full blocks spent, summed — the budget's denominator.
    public var blockChars: Int
    /// Characters the tier-0 lines spent.
    public var surfaceChars: Int
    public var budget: Int

    /// The sole init takes the rendering itself, so block text CANNOT be
    /// stored: there is no parameter to smuggle it through.
    public init(lane: PromptLane, rendering: AmbientRendering, budget: Int) {
        self.lane = lane
        self.mode = rendering.mode
        self.keys = rendering.keys
        self.blockCount = rendering.blocks.count
        self.mentionCount = rendering.mentions.count
        self.surfaceCount = rendering.surfaceLines.count
        self.blockChars = rendering.blocks.reduce(0) { $0 + $1.count }
        self.surfaceChars = rendering.surfaceLines.reduce(0) { $0 + $1.count }
        self.budget = budget
    }
}

/// One lane's budget waterfall for one turn. `PromptSpend` rows carry section
/// ids, outcomes, counts and a rationale line — no prompt text.
public struct PromptSpendTrace: Sendable, Equatable {
    public var lane: PromptLane
    public var spend: [PromptSpend]
    /// Characters appended AFTER the plan render (the guidance and projection
    /// tails), counted separately so the waterfall stays honest about what it
    /// does not itemize.
    public var appendedChars: Int
    /// The returned string's final count: plan text plus tails.
    public var totalChars: Int

    public init(
        lane: PromptLane,
        spend: [PromptSpend],
        appendedChars: Int,
        totalChars: Int
    ) {
        self.lane = lane
        self.spend = spend
        self.appendedChars = appendedChars
        self.totalChars = totalChars
    }
}

/// One exchange's retrieval story: the requests that went out, the
/// contribution that came back, and what each prompt lane spent.
public struct RetrievalTraceRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The user turn (`BrainTurn.id`) — the join key onto `AmbientTraceLog`'s
    /// rows and the transcript's bubbles.
    public var exchangeID: UUID
    /// The `AmbientTraceRecord.id` recorded beside this row's open, when the
    /// caller had one — a second join for rows whose exchange id predates it.
    public var routeTraceID: UUID?
    public var date: Date
    /// Usually one; TWO is the realtime pre-stream fallback made visible —
    /// the failed realtime request keeps its row entry, then the classic
    /// rerun appends its own.
    public var requests: [SeerRequestTrace]
    public var contribution: SeerContributionTrace?
    /// Which of `requests` the contribution answered — the row's last-booked
    /// request id at the moment the contribution arrived, derived by
    /// `noteContribution` itself.
    public var contributionRequestID: String?
    public var ambient: [AmbientInjectionTrace]
    public var promptSpend: [PromptSpendTrace]
}

/// Process-wide ring buffer of per-exchange retrieval rows.
public final class RetrievalTraceLedger: @unchecked Sendable {

    public static let shared = RetrievalTraceLedger()

    private let lock = NSLock()
    private var records: [RetrievalTraceRecord] = []
    private let capacity: Int
    /// See `stageSystemPrompt`.
    private var stagedSystemPrompt:
        (spend: PromptSpendTrace, ambient: AmbientInjectionTrace)?
    /// See `stageAbilityRequest`.
    private var stagedAbilityRequest: SeerRequestTrace?

    public init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    /// Opens the exchange's row — newest first, like `AmbientTraceLog`.
    /// Called beside that log's `record(...)` in the turn loop, BEFORE either
    /// lane exists, for the same reason the route row is: a turn that never
    /// finishes must still leave its trace.
    public func open(
        exchangeID: UUID,
        routeTraceID: UUID? = nil,
        date: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        records.insert(RetrievalTraceRecord(
            id: UUID(),
            exchangeID: exchangeID,
            routeTraceID: routeTraceID,
            date: date,
            requests: [],
            contribution: nil,
            contributionRequestID: nil,
            ambient: [],
            promptSpend: []), at: 0)
        if records.count > capacity { records.removeLast(records.count - capacity) }
    }

    /// Attach a sent request once the lane sees its `.scoped` event. A note
    /// for an evicted (or never-opened) row drops silently — the ring's
    /// contract, verbatim from `AmbientTraceLog`.
    public func noteSeerRequest(_ request: SeerRequestTrace, forExchange id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.exchangeID == id }) else { return }
        records[index].requests.append(request)
    }

    /// FIRST WINS, mirroring the lane's own `result.contribution` rule: a
    /// second contribution on one exchange is a duplicate, not a correction,
    /// and overwriting would let a fallback lane rewrite what the first lane
    /// was actually credited with.
    ///
    /// The request pairing is derived HERE, at booking time: a contribution
    /// answers the row's most recently booked request — on the two-request
    /// fallback shape, the classic rerun's own — so the rule lives beside
    /// the row it books instead of in a hand-carried local duplicated
    /// across both lane runners.
    public func noteContribution(
        _ contribution: SeerContributionTrace,
        forExchange id: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.exchangeID == id }),
              records[index].contribution == nil else { return }
        records[index].contribution = contribution
        records[index].contributionRequestID = records[index].requests.last?.id
    }

    public func noteAmbientInjection(
        _ injection: AmbientInjectionTrace, forExchange id: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.exchangeID == id }) else { return }
        records[index].ambient.append(injection)
    }

    public func notePromptSpend(_ spend: PromptSpendTrace, forExchange id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.exchangeID == id }) else { return }
        records[index].promptSpend.append(spend)
    }

    /// STAGE, DON'T BOOK: the system-prompt provider is deliberately zero-arg
    /// (`@Sendable () -> String`), so it cannot name the exchange it is
    /// building for. Threading an id through that seam would widen a closure
    /// five installs share for the benefit of one observer. Instead the
    /// provider stages its account here and the turn loop CLAIMS it onto the
    /// row it opens a few statements later — single producer (the turn loop's
    /// one prompt build), single consumer (the row-open beside it), both on
    /// the brain actor, so a stage can never belong to any turn but the one
    /// that claims next.
    public func stageSystemPrompt(
        spend: PromptSpendTrace, ambient: AmbientInjectionTrace
    ) {
        lock.lock()
        defer { lock.unlock() }
        stagedSystemPrompt = (spend, ambient)
    }

    /// Claims the staged system-prompt account onto the exchange's row. The
    /// stage is cleared EVEN when the row is missing — a stale stage
    /// attaching to some later exchange would be a row lying about whose
    /// prompt it describes, which is worse than a dropped note.
    public func claimStagedSystemPrompt(forExchange id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let staged = stagedSystemPrompt else { return }
        stagedSystemPrompt = nil
        guard let index = records.firstIndex(where: { $0.exchangeID == id }) else { return }
        records[index].promptSpend.append(staged.spend)
        records[index].ambient.append(staged.ambient)
    }

    /// Ability-lane gRPC search is asked during turn-context refresh, before
    /// the retrieval row exists. Stage here; the turn loop claims it onto the
    /// row it opens, same handshake as the system prompt.
    public func stageAbilityRequest(_ request: SeerRequestTrace) {
        lock.lock()
        defer { lock.unlock() }
        stagedAbilityRequest = request
    }

    public func claimStagedAbilityRequest(forExchange id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let staged = stagedAbilityRequest else { return }
        stagedAbilityRequest = nil
        guard let index = records.firstIndex(where: { $0.exchangeID == id }) else { return }
        records[index].requests.append(staged)
    }

    public func entries() -> [RetrievalTraceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
        stagedSystemPrompt = nil
        stagedAbilityRequest = nil
    }
}

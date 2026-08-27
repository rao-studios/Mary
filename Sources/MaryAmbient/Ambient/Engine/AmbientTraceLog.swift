//
//  AmbientTraceLog.swift
//  MaryBrain
//
//  WHAT THE ENGINE DECIDED, AND WHAT IT COST — one row per turn, newest
//  first.
//
//  Shaped exactly like `AbilityExecutionLog`: an NSLock-guarded ring buffer,
//  process-wide, in-memory, session-scoped. The totem archive is the durable
//  record; this is the last few turns, for the pane and for a pasted bug
//  report.
//
//  IT EXISTS BEFORE ANYTHING READS THE ROUTE, and that ordering is the point.
//  `AmbientRankingMode` carries `transformUnfocused` "so that fallback is
//  visible and pinnable rather than indistinguishable from the default";
//  `ReadDeliveryLedger` books nine honest routes for a read. A routing
//  decision with no ledger row would be the first unfalsifiable mechanism in
//  this area, and Ability routing is worth nothing without it.
//

import Foundation

/// One resolved turn, with the classifier verdicts that produced it and the
/// size of what actually went to the model.
public struct AmbientTraceRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    /// The user turn (`BrainTurn.id`) this row resolved — the same id the
    /// transcript stamps onto its bubbles, so a chat row and its route can be
    /// joined without guessing by position. Optional because the log predates
    /// the join: rows recorded by older paths simply never surface in it.
    public var exchangeID: UUID?
    public var utterance: String
    /// The decision AND the verdicts behind it — `route.verdicts` is the one
    /// computation, so a row in the pane can never disagree with the routing
    /// it claims to explain.
    public var route: AmbientRoute

    /// What the Ability execution lane's prompt actually weighed, in characters.
    public var systemPromptChars: Int
    /// The frozen registry revision and packages used by this turn. Studio
    /// edits activate only for a later turn and cannot reinterpret this row.
    public var registryRevision: UUID
    public var packageIDs: [PackageID]
    /// How many Skill schemas were exposed to the provider for this turn.
    public var exposedSkillCount: Int
    /// The exact closed arbitration that produced the package Skill roster.
    /// This contains schema identities and bounded scores, never raw values.
    public var abilityRoster: AbilityRosterTrace
    /// Structured, privacy-safe receipts in invocation order.
    public var skillRuns: [SkillRunReceipt]
    /// The responder-layer signal AT EXCHANGE TIME: realms with fresh
    /// evidence beside the lead, and which of them were only glanced.
    /// Stamped when the row is recorded — the lens must not re-read live
    /// tracker state onto an old row.
    public var coActiveRealms: [AmbientRealm]
    public var glancedRealms: Set<AmbientRealm>

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        exchangeID: UUID? = nil,
        utterance: String,
        route: AmbientRoute,
        systemPromptChars: Int = 0,
        registryRevision: UUID = EmptyAbilityCapabilityIndex.revisionID,
        packageIDs: [PackageID] = [],
        exposedSkillCount: Int = 0,
        abilityRoster: AbilityRosterTrace = .empty,
        skillRuns: [SkillRunReceipt] = [],
        coActiveRealms: [AmbientRealm] = [],
        glancedRealms: Set<AmbientRealm> = []
    ) {
        self.id = id
        self.date = date
        self.exchangeID = exchangeID
        self.utterance = utterance
        self.route = route
        self.systemPromptChars = systemPromptChars
        self.registryRevision = registryRevision
        self.packageIDs = packageIDs
        self.exposedSkillCount = exposedSkillCount
        self.abilityRoster = abilityRoster
        self.skillRuns = skillRuns
        self.coActiveRealms = coActiveRealms
        self.glancedRealms = glancedRealms
    }
}

/// Process-wide ring buffer of resolved turns.
public final class AmbientTraceLog: @unchecked Sendable {

    public static let shared = AmbientTraceLog()

    private let lock = NSLock()
    private var records: [AmbientTraceRecord] = []
    private let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    /// Newest first, like `AbilityExecutionLog`.
    public func record(_ record: AmbientTraceRecord) {
        lock.lock()
        defer { lock.unlock() }
        records.insert(record, at: 0)
        if records.count > capacity { records.removeLast(records.count - capacity) }
    }

    /// Attach a Skill invocation once the lane asks for it. Raw interaction
    /// values never enter this ledger; only schema identity and source scope
    /// travel in the receipt.
    ///
    /// A SEPARATE WRITE, because the two facts are known at different times:
    /// the route is resolved before either lane exists, and what the model
    /// reached for is only known after. Recording the row late instead would
    /// mean a turn that never finished — cancelled, superseded, stalled —
    /// left no trace at all, and those are the turns worth seeing.
    public func noteSkillInvocation(
        _ reference: AbilitySkillReference,
        effect: CapabilityEffect,
        inputTypes: [ValueTypeID] = [],
        outputTypes: [ValueTypeID] = [],
        consumedInteractions: [InteractionInstanceReference] = [],
        forTurn id: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].skillRuns.append(SkillRunReceipt(
            reference: reference,
            status: .running,
            effect: effect,
            inputTypes: inputTypes,
            outputTypes: outputTypes,
            consumedInteractions: consumedInteractions))
    }

    public func noteSkillResult(
        _ reference: AbilitySkillReference,
        status: SkillRunStatus,
        foundNothing: Bool = false,
        forTurn id: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let recordIndex = records.firstIndex(where: { $0.id == id }),
              let runIndex = records[recordIndex].skillRuns.lastIndex(where: {
                $0.reference == reference && $0.status == .running
              })
        else { return }
        records[recordIndex].skillRuns[runIndex].status = status
        records[recordIndex].skillRuns[runIndex].finishedAt = Date()
        records[recordIndex].skillRuns[runIndex].foundNothing = foundNothing
    }

    /// STAGE-0 COUNTER for the residual false-completion class: a non-action
    /// turn where the voice spoke and the lane landed nothing that mutates.
    /// Observation only — the numbers decide whether a fifth mechanism is
    /// ever built. Enforcing on prose ("Done", tense, negation) was
    /// considered and rejected as unshippable.
    private var voiceWithoutMutationCount = 0

    public func noteVoiceSpokeWithoutMutation() {
        lock.lock()
        defer { lock.unlock() }
        voiceWithoutMutationCount += 1
    }

    public func voiceWithoutMutationTally() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return voiceWithoutMutationCount
    }

    public func entries() -> [AmbientTraceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
    }
}

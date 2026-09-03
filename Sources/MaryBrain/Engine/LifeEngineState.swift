//
//  LifeEngineState.swift
//  MaryBrain
//
//  WHAT: What the Life engine is doing, what it decided, and why — the
//        vocabulary every monitor (sheet, pane, probe, log) reads.
//  IN:   MaryLifeEngine
//  OUT:  LifeEngineSnapshot / LifeEngineEvent
//  PIN:  Payload-free enums plus a `detail` string. A phase or a skip reason
//        is a thing to switch on; the sentence beside it is for a person.
//
import Foundation
import MaryFoundation

/// How much of itself the Life engine is allowed to be.
public enum LifeMode: String, Codable, Sendable, CaseIterable, Equatable {
    /// The loop does not run.
    case off
    /// Infer and record; never dispatch. The default — an adapter earns `.act`.
    case observe
    /// Dispatch under the engine's own gates.
    case act

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .observe: return "Observe"
        case .act: return "Act"
        }
    }
}

/// Where the loop is right now.
public enum LifeEnginePhase: String, Codable, Sendable, Equatable {
    case off
    /// Between pulses, eligible.
    case idle
    /// Between pulses, blocked by a condition (`phaseDetail` says which).
    case waiting
    case inferring
    case acting
    case cooldown
    case paused
    case failed
}

/// Why a pulse produced nothing. One case per gate, so a monitor can count them.
public enum LifeSkipReason: String, Codable, Sendable, Equatable {
    case modeOff
    case turnInFlight
    case skillRunning
    case indexing
    case userSpoke
    case userTyping
    case noLead
    case noReadyDiscipline
    case leadHasNoDiscipline
    case cooldown
    case budgetSpent
    case modelMismatch
    case adapterMissing
    case fleetUnreachable
    case pulseInFlight
}

/// The adapter a decision was made through — enough to name it without
/// touching the weights.
public struct LifeAdapterRef: Sendable, Equatable, Codable, Identifiable {
    public var abilityID: AbilityID
    public var cid: String
    public var generation: Int
    public var pairCount: Int
    public var modelID: String
    public var artifactPath: String
    public var ready: Bool
    public var training: Bool
    public var trainedAt: Date?

    public var id: String { abilityID.rawValue }

    /// Identity for the loaded session: new weights under the same path must
    /// reload, which is what `cid` (and only `cid`) changes on a retrain.
    public var sessionKey: String { "\(artifactPath)|\(cid)|\(modelID)" }

    public var shortCID: String { String(cid.prefix(8)) }

    public init(
        abilityID: AbilityID,
        cid: String,
        generation: Int,
        pairCount: Int,
        modelID: String,
        artifactPath: String,
        ready: Bool,
        training: Bool = false,
        trainedAt: Date? = nil
    ) {
        self.abilityID = abilityID
        self.cid = cid
        self.generation = generation
        self.pairCount = pairCount
        self.modelID = modelID
        self.artifactPath = artifactPath
        self.ready = ready
        self.training = training
        self.trainedAt = trainedAt
    }

    public init(slot: LifeLoRASlot) {
        self.init(
            abilityID: slot.abilityID,
            cid: slot.cid,
            generation: slot.generation,
            pairCount: slot.pairCount,
            modelID: slot.modelID,
            artifactPath: slot.artifactPath,
            ready: slot.ready,
            training: slot.training,
            trainedAt: slot.trainedAt)
    }
}

/// One pulse, start to finish. Every pulse produces exactly one of these,
/// including the ones that did nothing — a skipped pulse is a decision.
public struct LifeDecision: Sendable, Equatable, Codable, Identifiable {

    public enum Outcome: String, Codable, Sendable, Equatable {
        /// Actions ran.
        case acted
        /// Actions were predicted but held (observe mode, or an effectful
        /// skill the engine will not run unattended).
        case proposed
        /// The adapter chose to do nothing. Restraint is a result.
        case silent
        /// A gate refused before inference.
        case skipped
        /// Inference or decode failed.
        case dropped
    }

    public var id: UUID
    public var at: Date
    public var mode: LifeMode
    public var outcome: Outcome
    public var skip: LifeSkipReason?
    /// The sentence a person reads. Never empty for `.skipped` / `.dropped`.
    public var detail: String
    public var discipline: AbilityID?
    public var adapter: LifeAdapterRef?
    public var input: BehavioralTrainingInput?
    public var output: BehavioralTrainingOutput?
    public var actionCount: Int
    public var inferenceMs: Int
    /// Share of tokens the schema forced rather than the adapter choosing.
    public var forcedFraction: Double
    public var promptTokens: Int
    /// The episode this pulse sealed, when it opened one.
    public var episodeID: UUID?

    public init(
        id: UUID = UUID(),
        at: Date,
        mode: LifeMode,
        outcome: Outcome,
        skip: LifeSkipReason? = nil,
        detail: String = "",
        discipline: AbilityID? = nil,
        adapter: LifeAdapterRef? = nil,
        input: BehavioralTrainingInput? = nil,
        output: BehavioralTrainingOutput? = nil,
        actionCount: Int = 0,
        inferenceMs: Int = 0,
        forcedFraction: Double = 0,
        promptTokens: Int = 0,
        episodeID: UUID? = nil
    ) {
        self.id = id
        self.at = at
        self.mode = mode
        self.outcome = outcome
        self.skip = skip
        self.detail = detail
        self.discipline = discipline
        self.adapter = adapter
        self.input = input
        self.output = output
        self.actionCount = actionCount
        self.inferenceMs = inferenceMs
        self.forcedFraction = forcedFraction
        self.promptTokens = promptTokens
        self.episodeID = episodeID
    }

    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    /// One log/monitor line: `acted writing gen3 · 412ms · 2 actions`.
    public var line: String {
        var parts = [outcome.rawValue]
        if let discipline { parts.append(discipline.rawValue) }
        if let adapter { parts.append("gen\(adapter.generation)") }
        if inferenceMs > 0 { parts.append("\(inferenceMs)ms") }
        if actionCount > 0 {
            parts.append("\(actionCount) action\(actionCount == 1 ? "" : "s")")
        }
        if !detail.isEmpty { parts.append("— \(detail)") }
        return parts.joined(separator: " · ")
    }
}

/// Everything a monitor needs in one value. Read without dialing anything.
public struct LifeEngineSnapshot: Sendable, Equatable {
    public var mode: LifeMode
    public var phase: LifeEnginePhase
    public var phaseDetail: String
    /// Every discipline slot the engine knows about, sorted by ability.
    public var adapters: [LifeAdapterRef]
    /// The adapter currently resident in the codec session, if any.
    public var loadedAdapter: LifeAdapterRef?
    public var lastDecision: LifeDecision?
    /// Newest first, capped at the engine's history limit.
    public var recent: [LifeDecision]
    public var nextEligibleAt: Date?
    public var cooldownUntil: Date?
    public var actsToday: Int
    public var dailyActBudget: Int
    public var fleetReachable: Bool
    public var startedAt: Date?
    /// Newest first, capped at 6.
    public var errorTail: [String]

    public init(
        mode: LifeMode = .off,
        phase: LifeEnginePhase = .off,
        phaseDetail: String = "",
        adapters: [LifeAdapterRef] = [],
        loadedAdapter: LifeAdapterRef? = nil,
        lastDecision: LifeDecision? = nil,
        recent: [LifeDecision] = [],
        nextEligibleAt: Date? = nil,
        cooldownUntil: Date? = nil,
        actsToday: Int = 0,
        dailyActBudget: Int = 0,
        fleetReachable: Bool = true,
        startedAt: Date? = nil,
        errorTail: [String] = []
    ) {
        self.mode = mode
        self.phase = phase
        self.phaseDetail = phaseDetail
        self.adapters = adapters
        self.loadedAdapter = loadedAdapter
        self.lastDecision = lastDecision
        self.recent = recent
        self.nextEligibleAt = nextEligibleAt
        self.cooldownUntil = cooldownUntil
        self.actsToday = actsToday
        self.dailyActBudget = dailyActBudget
        self.fleetReachable = fleetReachable
        self.startedAt = startedAt
        self.errorTail = errorTail
    }

    public var readyCount: Int { adapters.filter(\.ready).count }
    public var isTraining: Bool { adapters.contains(where: \.training) }
}

/// Live engine activity. One stream, so a monitor never polls.
public enum LifeEngineEvent: Sendable {
    case modeChanged(LifeMode)
    case phaseChanged(LifeEnginePhase, detail: String)
    case decision(LifeDecision)
    case adaptersChanged([LifeAdapterRef])
    case adapterLoaded(LifeAdapterRef)
    case adapterUnloaded(cid: String)
    case failed(String)
}

/// Knobs. Defaults are the shipped policy.
public struct LifeEngineConfig: Sendable, Equatable {
    /// Seconds between pulses.
    public var period: TimeInterval
    /// Quiet needed after the last user turn.
    public var quietAfterUser: TimeInterval
    /// Quiet needed after the last keyboard/mouse event. Nil-valued input
    /// (no HID source) never blocks — the gate reports what it knows.
    public var quietAfterInput: TimeInterval
    /// Enforced rest after a pulse that actually acted.
    public var actCooldown: TimeInterval
    /// Acts per calendar day, `.act` mode only.
    public var dailyActBudget: Int
    public var historyLimit: Int
    /// Consecutive pulses that did not reach inference before the loaded
    /// adapter is let go. A resident adapter pins a full copy of the base
    /// model; most pulses refuse at a gate and never touch it, so holding it
    /// through a quiet afternoon costs gigabytes for nothing.
    public var idlePulsesBeforeUnload: Int

    public init(
        period: TimeInterval = 45,
        quietAfterUser: TimeInterval = 45,
        quietAfterInput: TimeInterval = 120,
        actCooldown: TimeInterval = 600,
        dailyActBudget: Int = 20,
        historyLimit: Int = 20,
        idlePulsesBeforeUnload: Int = 4
    ) {
        self.period = period
        self.quietAfterUser = quietAfterUser
        self.quietAfterInput = quietAfterInput
        self.actCooldown = actCooldown
        self.dailyActBudget = dailyActBudget
        self.historyLimit = historyLimit
        self.idlePulsesBeforeUnload = idlePulsesBeforeUnload
    }
}

/// The world as the gates see it, at one instant.
public struct LifeConditions: Sendable, Equatable {
    public var isTurnInFlight: Bool
    public var isSkillRunning: Bool
    /// The unit-index idle debounce is still waiting.
    public var isWorkspaceIndexing: Bool
    public var lastUserEpisodeAt: Date?
    /// Seconds since the last keyboard/mouse event. Nil = no HID source.
    public var secondsSinceUserInput: TimeInterval?
    public var now: Date

    public init(
        isTurnInFlight: Bool = false,
        isSkillRunning: Bool = false,
        isWorkspaceIndexing: Bool = false,
        lastUserEpisodeAt: Date? = nil,
        secondsSinceUserInput: TimeInterval? = nil,
        now: Date = Date()
    ) {
        self.isTurnInFlight = isTurnInFlight
        self.isSkillRunning = isSkillRunning
        self.isWorkspaceIndexing = isWorkspaceIndexing
        self.lastUserEpisodeAt = lastUserEpisodeAt
        self.secondsSinceUserInput = secondsSinceUserInput
        self.now = now
    }
}

/// The quiet world, projected the way a training row is projected.
public struct LifeWorld: Sendable, Equatable {
    public var input: BehavioralTrainingInput
    /// Disciplines the lead place declares, in preference order. Empty when
    /// nothing is in front — the engine will not reach for an unrelated one.
    public var leadDisciplines: [AbilityID]
    /// What the lead place is called, for the monitor line.
    public var leadLabel: String

    public init(
        input: BehavioralTrainingInput,
        leadDisciplines: [AbilityID],
        leadLabel: String
    ) {
        self.input = input
        self.leadDisciplines = leadDisciplines
        self.leadLabel = leadLabel
    }
}

/// One gated completion, plus what the gate did.
public struct LifeCompletion: Sendable, Equatable {
    public var output: BehavioralTrainingOutput
    public var forcedFraction: Double
    public var promptTokens: Int

    public init(
        output: BehavioralTrainingOutput,
        forcedFraction: Double = 0,
        promptTokens: Int = 0
    ) {
        self.output = output
        self.forcedFraction = forcedFraction
        self.promptTokens = promptTokens
    }
}

public enum LifeEngineError: Error, Sendable, Equatable {
    case invalidSchema
    case modelMismatch(expected: String, got: String)
    case noAdapter
}

// MARK: - Seams

/// Ready adapters, from wherever they come from. The engine never dials Fleet.
public protocol LifeSlotProviding: Sendable {
    func adapters() async -> (slots: [AbilityID: LifeLoRASlot], reachable: Bool)
}

/// The gate inputs the engine cannot read for itself.
public protocol LifeConditionsProviding: Sendable {
    func conditions() async -> LifeConditions
}

/// The quiet world as a training-shaped input.
public protocol LifeWorldProviding: Sendable {
    func pulseWorld() async -> LifeWorld?
}

/// A loaded adapter that can answer one gated completion.
public protocol LifeAdapterSessioning: Sendable {
    func complete(
        input: BehavioralTrainingInput, schemaJSON: Data
    ) async throws -> LifeCompletion
}

/// Makes a session for one adapter. Separated so the engine owns the cache
/// (and its reload rule) while the MLX work stays behind a seam.
public protocol LifeAdapterSessionMaking: Sendable {
    func makeSession(adapter: LifeAdapterRef) throws -> any LifeAdapterSessioning
}

//
//  AmbientIdlePulse.swift
//  MaryAmbient
//
//  A snapshot of the quiet world as a BehavioralInput, plus a discipline
//  hint. Runtime is the only consumer that infers and dispatches. This
//  layer does not import Totem or Fleet.
//

import Foundation
import MaryFoundation

public struct AmbientIdlePulse: Sendable, Equatable {
    public var input: BehavioralTrainingInput
    public var abilityHint: AbilityTotemTarget?
    public var capturedAt: Date

    public init(
        input: BehavioralTrainingInput,
        abilityHint: AbilityTotemTarget?,
        capturedAt: Date = Date()
    ) {
        self.input = input
        self.abilityHint = abilityHint
        self.capturedAt = capturedAt
    }

    public struct Conditions: Sendable {
        public var isTurnInFlight: Bool
        public var isSkillRunning: Bool
        /// The 12s unit-index idle debounce is still waiting.
        public var isWorkspaceIndexing: Bool
        public var lastUserEpisodeAt: Date?
        public var now: Date

        public init(
            isTurnInFlight: Bool,
            isSkillRunning: Bool,
            isWorkspaceIndexing: Bool = false,
            lastUserEpisodeAt: Date?,
            now: Date = Date()
        ) {
            self.isTurnInFlight = isTurnInFlight
            self.isSkillRunning = isSkillRunning
            self.isWorkspaceIndexing = isWorkspaceIndexing
            self.lastUserEpisodeAt = lastUserEpisodeAt
            self.now = now
        }
    }

    public struct Config: Sendable {
        public var period: TimeInterval
        public var quietAfterUser: TimeInterval

        public init(period: TimeInterval = 45, quietAfterUser: TimeInterval = 45) {
            self.period = period
            self.quietAfterUser = quietAfterUser
        }
    }

    /// Whether the world is quiet enough to emit a pulse.
    public static func shouldFire(_ conditions: Conditions, config: Config = Config()) -> Bool {
        guard !conditions.isTurnInFlight,
              !conditions.isSkillRunning,
              !conditions.isWorkspaceIndexing
        else { return false }
        if let last = conditions.lastUserEpisodeAt,
           conditions.now.timeIntervalSince(last) < config.quietAfterUser
        {
            return false
        }
        return true
    }

    public static func make(
        store: AmbientContextStore,
        profiles: [ApplicationProfile],
        readyDisciplines: Set<AbilityID>,
        abilities: any AbilityCapabilityIndex = AmbientCapabilityIndexProvider.current,
        now: Date = Date()
    ) -> AmbientIdlePulse {
        let lead = store.leadPlace(at: now)
        let facts = store.facts(at: now)
        let query: String
        if let lead {
            query = "idle · \(lead.displayName)"
        } else {
            query = "idle"
        }
        let summaryParts = [lead?.displayName].compactMap { $0 }
            + facts.prefix(8).map(\.content)
        var summary = summaryParts.joined(separator: " ")
        if summary.count > 500 {
            summary = String(summary.prefix(500))
        }
        let input = BehavioralTrainingInput(
            query: query,
            ambientMode: lead == nil ? "" : "focusedWorld",
            ambientLead: lead?.memoryToken ?? "",
            factCount: facts.count,
            ambientSummary: summary)
        let hint = abilityHint(
            lead: lead,
            profiles: profiles,
            readyDisciplines: readyDisciplines,
            abilities: abilities)
        return AmbientIdlePulse(input: input, abilityHint: hint, capturedAt: now)
    }

    public static func abilityHint(
        lead: AmbientPlace?,
        profiles: [ApplicationProfile],
        readyDisciplines: Set<AbilityID>,
        abilities: any AbilityCapabilityIndex = AmbientCapabilityIndexProvider.current
    ) -> AbilityTotemTarget? {
        var targets: [AbilityTotemTarget] = []
        if let leadID = lead?.application,
           let profile = profiles.first(where: { $0.id == leadID })
        {
            targets = profile.abilities.sorted { $0.rawValue < $1.rawValue }.map { id in
                AbilityTotemTarget(
                    abilityID: id,
                    paradigm: abilities.paradigm(of: id) ?? .discipline)
            }
        }
        if let ready = targets.first(where: {
            $0.paradigm == .discipline && readyDisciplines.contains($0.abilityID)
        }) {
            return ready
        }
        if let anyReady = readyDisciplines.sorted(by: { $0.rawValue < $1.rawValue }).first {
            return AbilityTotemTarget(abilityID: anyReady, paradigm: .discipline)
        }
        return targets.first { $0.paradigm == .discipline }
    }
}

/// One pulse at a time. Runtime is the only consumer.
public actor AmbientIdlePulseSource {
    private let config: AmbientIdlePulse.Config
    private var inFlight = false

    public init(config: AmbientIdlePulse.Config = .init()) {
        self.config = config
    }

    public func beginIfReady(
        conditions: AmbientIdlePulse.Conditions,
        store: AmbientContextStore,
        profiles: [ApplicationProfile],
        readyDisciplines: Set<AbilityID>
    ) -> AmbientIdlePulse? {
        guard !inFlight,
              AmbientIdlePulse.shouldFire(conditions, config: config)
        else { return nil }
        inFlight = true
        return AmbientIdlePulse.make(
            store: store,
            profiles: profiles,
            readyDisciplines: readyDisciplines,
            now: conditions.now)
    }

    public func endPulse() {
        inFlight = false
    }

    public var period: TimeInterval { config.period }
}

//
//  BehavioralTrainingPair.swift
//  MaryFoundation
//
//  THE FROZEN SPINE FLEET GATES ON. A sealed BehavioralEpisode is a rich,
//  optional-heavy codec; Fleet's schema automaton requires every training
//  output to carry the identical keys and value types. This pair is that
//  projection: always-present keys, empty strings for absences (JSON null
//  vs string is a type mismatch the extractor will not reconcile).
//
//  Not a second schema version. The episode remains mary.behavior; this is
//  how one episode becomes one INPUT:/OUTPUT: example and how a gated
//  decode becomes an episode again. AX geometry is dropped on purpose —
//  it is not stable across turns and would blow the automaton. Live AX at
//  infer time is the current ambient world.
//

import Foundation

/// One Fleet training/inference example, projected from a BehavioralEpisode.
public struct BehavioralTrainingPair: Hashable, Sendable {
    public var input: BehavioralTrainingInput
    public var output: BehavioralTrainingOutput

    public init(input: BehavioralTrainingInput, output: BehavioralTrainingOutput) {
        self.input = input
        self.output = output
    }

    public init(episode: BehavioralEpisode, summaryLimit: Int = 500) {
        input = BehavioralTrainingInput(episode: episode, summaryLimit: summaryLimit)
        output = BehavioralTrainingOutput(episode: episode)
    }

    /// Sorted-key JSON, one object, no pretty-print — the bytes Fleet hashes.
    public func encodedInput() throws -> Data {
        try BehavioralCodec.encoder().encode(input)
    }

    public func encodedOutput() throws -> Data {
        try BehavioralCodec.encoder().encode(output)
    }
}

/// Frozen input half. Every key is always present.
public struct BehavioralTrainingInput: Codable, Hashable, Sendable {
    public var query: String
    public var priorEpisodeID: String
    public var ambientMode: String
    public var ambientLead: String
    public var factCount: Int
    public var ambientSummary: String

    public init(
        query: String,
        priorEpisodeID: String = "",
        ambientMode: String = "",
        ambientLead: String = "",
        factCount: Int = 0,
        ambientSummary: String = ""
    ) {
        self.query = query
        self.priorEpisodeID = priorEpisodeID
        self.ambientMode = ambientMode
        self.ambientLead = ambientLead
        self.factCount = factCount
        self.ambientSummary = ambientSummary
    }

    public init(episode: BehavioralEpisode, summaryLimit: Int = 500) {
        self.init(input: episode.input, summaryLimit: summaryLimit)
    }

    public init(input: BehavioralInput, summaryLimit: Int = 500) {
        query = input.query
        priorEpisodeID = input.priorEpisodeID?.uuidString.lowercased() ?? ""
        ambientMode = input.ambient?.mode ?? ""
        ambientLead = input.ambient?.lead ?? ""
        factCount = input.ambient?.facts.count ?? 0
        ambientSummary = Self.summary(from: input.ambient, limit: summaryLimit)
    }

    /// Rebuild the episode input. Empty strings become nils; the capture is
    /// a stub (mode/lead only) because the pair never stored AX geometry.
    public func makeInput() -> BehavioralInput {
        let prior = UUID(uuidString: priorEpisodeID)
        let ambient: AmbientCapture?
        if ambientMode.isEmpty && ambientLead.isEmpty && factCount == 0
            && ambientSummary.isEmpty
        {
            ambient = nil
        } else {
            ambient = AmbientCapture(
                mode: ambientMode,
                lead: ambientLead.isEmpty ? nil : ambientLead,
                renderedBlocks: ambientSummary.isEmpty ? [] : [ambientSummary])
        }
        return BehavioralInput(query: query, ambient: ambient, priorEpisodeID: prior)
    }

    private static func summary(from capture: AmbientCapture?, limit: Int) -> String {
        guard let capture else { return "" }
        var parts: [String] = []
        if let lead = capture.lead, !lead.isEmpty { parts.append(lead) }
        parts.append(contentsOf: capture.renderedBlocks)
        parts.append(contentsOf: capture.renderedMentions)
        let joined = parts.joined(separator: " ")
        guard joined.count > limit else { return joined }
        let end = joined.index(joined.startIndex, offsetBy: limit)
        return String(joined[..<end])
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case priorEpisodeID = "prior_episode_id"
        case ambientMode = "ambient_mode"
        case ambientLead = "ambient_lead"
        case factCount = "fact_count"
        case ambientSummary = "ambient_summary"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        query = try values.decode(String.self, forKey: .query)
        priorEpisodeID = try values.decode(String.self, forKey: .priorEpisodeID)
        ambientMode = try values.decode(String.self, forKey: .ambientMode)
        ambientLead = try values.decode(String.self, forKey: .ambientLead)
        factCount = try values.decode(Int.self, forKey: .factCount)
        ambientSummary = try values.decode(String.self, forKey: .ambientSummary)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(query, forKey: .query)
        try values.encode(priorEpisodeID, forKey: .priorEpisodeID)
        try values.encode(ambientMode, forKey: .ambientMode)
        try values.encode(ambientLead, forKey: .ambientLead)
        try values.encode(factCount, forKey: .factCount)
        try values.encode(ambientSummary, forKey: .ambientSummary)
    }
}

/// Frozen output half. Array length may vary; action keys may not.
public struct BehavioralTrainingOutput: Codable, Hashable, Sendable {
    public var actions: [Action]

    public struct Action: Codable, Hashable, Sendable {
        public var intention: String
        public var argumentsJSON: String
        public var skillID: String
        public var invocationName: String
        public var disposition: String
        public var summary: String

        public init(
            intention: String,
            argumentsJSON: String = "{}",
            skillID: String,
            invocationName: String,
            disposition: String,
            summary: String = ""
        ) {
            self.intention = intention
            self.argumentsJSON = argumentsJSON
            self.skillID = skillID
            self.invocationName = invocationName
            self.disposition = disposition
            self.summary = summary
        }

        private enum CodingKeys: String, CodingKey {
            case intention
            case argumentsJSON = "arguments_json"
            case skillID = "skill_id"
            case invocationName = "invocation_name"
            case disposition
            case summary
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            intention = try values.decode(String.self, forKey: .intention)
            argumentsJSON = try values.decode(String.self, forKey: .argumentsJSON)
            skillID = try values.decode(String.self, forKey: .skillID)
            invocationName = try values.decode(String.self, forKey: .invocationName)
            disposition = try values.decode(String.self, forKey: .disposition)
            summary = try values.decode(String.self, forKey: .summary)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(intention, forKey: .intention)
            try values.encode(argumentsJSON, forKey: .argumentsJSON)
            try values.encode(skillID, forKey: .skillID)
            try values.encode(invocationName, forKey: .invocationName)
            try values.encode(disposition, forKey: .disposition)
            try values.encode(summary, forKey: .summary)
        }
    }

    public init(actions: [Action] = []) {
        self.actions = actions
    }

    public init(episode: BehavioralEpisode) {
        actions = episode.output.actions.map { record in
            Action(
                intention: record.action.intention,
                argumentsJSON: record.action.argumentsJSON,
                skillID: record.action.skill.skillID.rawValue,
                invocationName: record.action.skill.invocationName,
                disposition: record.disposition.rawValue,
                summary: record.summary)
        }
    }

    /// Re-encode a predicted output as a sealed-ready episode. Timestamps and
    /// identity are minted here; AX targets stay empty for the live world.
    public func makeEpisode(
        id: UUID,
        input: BehavioralInput,
        provenance: EpisodeProvenance,
        abilityTargets: [AbilityTotemTarget] = [],
        openedAt: Date = Date()
    ) -> BehavioralEpisode {
        let records: [BehavioralActionRecord] = actions.enumerated().map { index, action in
            let skill = AbilitySkillReference(
                packageID: PackageID("fleet.life"),
                packageVersion: SemanticVersion("1.0.0"),
                abilityID: abilityTargets.first?.abilityID ?? AbilityID(action.skillID),
                abilityTitle: abilityTargets.first?.abilityID.rawValue ?? action.skillID,
                abilityTint: "none",
                skillID: SkillID(action.skillID),
                skillTitle: action.intention,
                invocationName: action.invocationName.isEmpty
                    ? action.intention : action.invocationName,
                source: .runtime)
            let disposition = BehavioralDisposition(rawValue: action.disposition)
                ?? .unknown
            return BehavioralActionRecord(
                id: "life-\(id.uuidString.lowercased())-\(index)",
                action: BehavioralAction(
                    intention: action.intention,
                    argumentsJSON: action.argumentsJSON.isEmpty ? "{}" : action.argumentsJSON,
                    skill: skill),
                disposition: disposition,
                summary: action.summary,
                startedAt: openedAt)
        }
        return BehavioralEpisode(
            id: id,
            openedAt: openedAt,
            input: input,
            output: BehavioralOutput(actions: records),
            provenance: provenance,
            abilityTargets: abilityTargets)
    }

    private enum CodingKeys: String, CodingKey { case actions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        actions = try values.decode([Action].self, forKey: .actions)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(actions, forKey: .actions)
    }
}

//
//  BehavioralEpisode.swift
//  MaryFoundation
//
//  WHAT: One turn — query + injected AmbientCapture + action sequence.
//  IN:   user-turn UUID (episode id); priorEpisodeID chains history.
//  OUT:  BehavioralCodec, LifeTrainPolicy, Totem.
//  PIN:  Seal with a reason; never drop superseded turns here. Filter at train time.
//        Synthesized Codable — see BehavioralAction.
//

import Foundation

/// Why the episode stopped. Part of the data — interrupt vs complete differ.
public enum EpisodeSealReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// Finished on its own.
    case completed
    /// Newer turn replaced this one.
    case superseded
    /// Stopped before finishing.
    case cancelled
    /// App quitting. In-flight actions stay `.unsettled`.
    case appQuit
    /// Unknown to this build. Decode-only.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EpisodeSealReason(rawValue: raw) ?? .unknown
    }
}

/// Query plus injected context.
public struct BehavioralInput: Codable, Hashable, Sendable {

    /// User words.
    public var query: String

    /// Injected context. Nil = no prompt; empty capture = assembled, nothing to see.
    public var ambient: AmbientCapture?

    /// Previous episode in this conversation.
    public var priorEpisodeID: UUID?

    public init(query: String, ambient: AmbientCapture? = nil, priorEpisodeID: UUID? = nil) {
        self.query = query
        self.ambient = ambient
        self.priorEpisodeID = priorEpisodeID
    }

    private enum CodingKeys: String, CodingKey {
        case query, ambient, priorEpisodeID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        query = try values.decodeIfPresent(String.self, forKey: .query) ?? ""
        ambient = try values.decodeIfPresent(AmbientCapture.self, forKey: .ambient)
        priorEpisodeID = try values.decodeIfPresent(UUID.self, forKey: .priorEpisodeID)
    }
}

/// Actions in compose order.
public struct BehavioralOutput: Codable, Hashable, Sendable {

    /// Composed actions. Empty = conversation / restraint — still a row.
    public var actions: [BehavioralActionRecord]

    public init(actions: [BehavioralActionRecord] = []) {
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey { case actions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        actions = try values.decodeIfPresent([BehavioralActionRecord].self, forKey: .actions) ?? []
    }
}

/// Build, engine, lane. Filter datasets rather than mixing engines.
public struct EpisodeProvenance: Codable, Hashable, Sendable {
    /// Acting-lane engine.
    public var engine: String
    /// Dual-lane vs offline fallback.
    public var lane: String
    /// Producing build.
    public var appVersion: String

    public init(engine: String, lane: String, appVersion: String) {
        self.engine = engine
        self.lane = lane
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey { case engine, lane, appVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decodeIfPresent(String.self, forKey: .engine) ?? ""
        lane = try values.decodeIfPresent(String.self, forKey: .lane) ?? ""
        appVersion = try values.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
    }
}

/// One turn: asked, visible, done.
public struct BehavioralEpisode: Codable, Hashable, Sendable, Identifiable {

    /// Wire format id. Reject wrong files before other fields.
    public static let schemaName = "mary.behavior"

    /// Bump when a field's meaning changes; new optionals do not.
    public static let currentSchemaVersion = 1

    public var schema: String
    public var schemaVersion: Int

    /// User-turn UUID. Not a new identity.
    public var id: UUID

    public var openedAt: Date
    public var sealedAt: Date?
    public var sealedReason: EpisodeSealReason?

    public var input: BehavioralInput
    public var output: BehavioralOutput
    public var provenance: EpisodeProvenance
    /// Totem groups. Empty = no Ability write, no Personal stub.
    public var abilityTargets: [AbilityTotemTarget]

    public init(
        id: UUID,
        openedAt: Date,
        sealedAt: Date? = nil,
        sealedReason: EpisodeSealReason? = nil,
        input: BehavioralInput,
        output: BehavioralOutput = .init(),
        provenance: EpisodeProvenance,
        abilityTargets: [AbilityTotemTarget] = []
    ) {
        self.schema = Self.schemaName
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.openedAt = openedAt
        self.sealedAt = sealedAt
        self.sealedReason = sealedReason
        self.input = input
        self.output = output
        self.provenance = provenance
        self.abilityTargets = Array(Set(abilityTargets)).sorted()
    }

    /// Stopped taking actions.
    public var isSealed: Bool { sealedReason != nil }

    /// Seal once. First reason wins — barge-in then quit-flush stays cancelled.
    public mutating func seal(_ reason: EpisodeSealReason, at date: Date = Date()) {
        guard sealedReason == nil else { return }
        sealedReason = reason
        sealedAt = date
    }

    /// Anything ran. Train-set filter (acted vs restraint).
    public var didAct: Bool {
        output.actions.contains { $0.disposition.didRun }
    }

    private enum CodingKeys: String, CodingKey {
        case schema, schemaVersion, id, openedAt, sealedAt, sealedReason
        case input, output, provenance, abilityTargets
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decodeIfPresent(String.self, forKey: .schema) ?? Self.schemaName
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        id = try values.decode(UUID.self, forKey: .id)
        openedAt = try values.decode(Date.self, forKey: .openedAt)
        sealedAt = try values.decodeIfPresent(Date.self, forKey: .sealedAt)
        sealedReason = try values.decodeIfPresent(EpisodeSealReason.self, forKey: .sealedReason)
        input = try values.decode(BehavioralInput.self, forKey: .input)
        output = try values.decodeIfPresent(BehavioralOutput.self, forKey: .output) ?? .init()
        provenance = try values.decodeIfPresent(
            EpisodeProvenance.self, forKey: .provenance)
            ?? .init(engine: "", lane: "", appVersion: "")
        abilityTargets = try values.decodeIfPresent(
            [AbilityTotemTarget].self, forKey: .abilityTargets) ?? []
    }
}

/// Personal-lane pointer. Join on episodeID / abilityDocumentID — not a copy.
public struct BehavioralInteractionStub: Codable, Hashable, Sendable {
    public var episodeID: UUID
    public var query: String
    public var priorEpisodeID: UUID?
    public var abilityDocumentID: String
    public var abilityGroupIDs: [String]
    public var sealedReason: String?
    public var didAct: Bool

    public init(
        episodeID: UUID,
        query: String,
        priorEpisodeID: UUID? = nil,
        abilityDocumentID: String,
        abilityGroupIDs: [String],
        sealedReason: String? = nil,
        didAct: Bool
    ) {
        self.episodeID = episodeID
        self.query = query
        self.priorEpisodeID = priorEpisodeID
        self.abilityDocumentID = abilityDocumentID
        self.abilityGroupIDs = abilityGroupIDs
        self.sealedReason = sealedReason
        self.didAct = didAct
    }

    private enum CodingKeys: String, CodingKey {
        case episodeID = "episode_id"
        case query
        case priorEpisodeID = "prior_episode_id"
        case abilityDocumentID = "ability_document_id"
        case abilityGroupIDs = "ability_group_ids"
        case sealedReason = "sealed_reason"
        case didAct = "did_act"
    }
}

/// Encoder/decoder. Sorted keys, ISO-8601 with milliseconds, no pretty-print
/// (newline is the record separator). PIN: Foundation `.iso8601` drops fractions
/// and would collapse in-turn order.
public enum BehavioralCodec {

    /// ISO-8601 milliseconds UTC. Shared formatter.
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// With or without fractional seconds (hand / older builds).
    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = dateFormatter.date(from: text) { return date }
            if let date = plainFormatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not an ISO-8601 timestamp: \(text)"))
        }
        return decoder
    }

    /// One episode, one JSON line, no trailing newline.
    public static func line(_ episode: BehavioralEpisode) throws -> Data {
        try encoder().encode(episode)
    }

    public static func episode(from line: Data) throws -> BehavioralEpisode {
        try decoder().decode(BehavioralEpisode.self, from: line)
    }
}

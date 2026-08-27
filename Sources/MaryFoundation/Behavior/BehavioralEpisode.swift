//
//  BehavioralEpisode.swift
//  MaryFoundation
//
//  ONE TURN, INPUT AND OUTPUT — the unit of the behavioural codec.
//
//  What was asked, what Mary could see when she was asked, and everything she
//  did about it. This is the row a future model trains on and the row a
//  future model would emit: the input half is a query plus the context that
//  was actually injected, the output half is a SEQUENCE of actions, and a
//  sequence is the point — a procedure is several actions that belong
//  together, and taking them apart into isolated pairs would throw away the
//  structure that makes automation possible.
//
//  THE EPISODE IS A TURN, AND ITS ID IS THE TURN'S. Not a new identity: the
//  user turn's UUID already flows through the whole system, so an episode can
//  be joined to a transcript row, a trace and a retrieval record without
//  anybody minting a correlation key. `priorEpisodeID` chains episodes rather
//  than embedding history — the conversation stays reconstructable without
//  every row carrying a copy of the ones before it.
//
//  NOTHING IS EVER DELETED. An episode is sealed with a REASON, including
//  when the turn was cancelled or superseded, and the sealed episode is kept.
//  The conversation may be purged — the user asked for that, and a transcript
//  is a record of what was said. Behaviour is a record of what was DONE, and
//  actions that ran changed the world whether or not the turn that started
//  them survived. A dataset that quietly dropped superseded turns would teach
//  a future model that interrupted work never happens, when interrupted work
//  is most of what an assistant does. Filter on `sealedReason` at training
//  time; do not filter here.
//
//  SCHEMA-VERSIONED AND TOLERANT. Every file carries `schema` and
//  `schemaVersion` so a reader can tell what it is holding before trusting a
//  field, and decoding accepts absent optionals and unknown keys — see
//  `BehavioralAction.swift`'s header on why this layer is deliberately not
//  the strict package decoder.
//

import Foundation

/// Why an episode stopped taking actions.
///
/// Part of the data, not bookkeeping: an episode that ended because the user
/// interrupted describes different behaviour than one that ran to completion,
/// and a model trained without the distinction would learn to treat the two
/// the same.
public enum EpisodeSealReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// The turn finished on its own terms.
    case completed
    /// A newer turn replaced this one — the user amended, or spoke over it.
    case superseded
    /// Stopped before finishing.
    case cancelled
    /// The application was quitting. Actions still in flight are `.unsettled`.
    case appQuit
    /// A reason this build does not know. Decode-only — never written.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EpisodeSealReason(rawValue: raw) ?? .unknown
    }
}

/// What was asked, and what could be seen when it was asked.
public struct BehavioralInput: Codable, Hashable, Sendable {

    /// The user's words, as transcribed or typed.
    public var query: String

    /// The context injected for this turn.
    ///
    /// Nil means no context was assembled — a deterministic path that never
    /// built a prompt, such as answering a bare "yes" to a pending question.
    /// An empty capture means one was assembled and there was nothing to see.
    /// The distinction is deliberate; see `AmbientCapture`'s header.
    public var ambient: AmbientCapture?

    /// The previous episode in this conversation, if there was one.
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

/// Everything Mary did about it, in order.
public struct BehavioralOutput: Codable, Hashable, Sendable {

    /// The actions this turn produced, in the order they were composed.
    ///
    /// An empty array is a real and common answer: the turn was conversation,
    /// and Mary correctly did nothing. Those rows matter as much as the ones
    /// with actions — a model that never learns when NOT to act is worse than
    /// no model.
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

/// Which build, engine and lane produced an episode.
///
/// Behaviour is not comparable across engines: the same query answered by a
/// local model and a hosted one is two different observations. Recording it
/// means a dataset can be filtered rather than silently mixed.
public struct EpisodeProvenance: Codable, Hashable, Sendable {
    /// The inference engine that drove the acting lane.
    public var engine: String
    /// Which turn shape ran — the dual-lane path, or the offline fallback.
    public var lane: String
    /// The build that produced this episode.
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

/// One turn: what was asked, what was visible, and what was done.
public struct BehavioralEpisode: Codable, Hashable, Sendable, Identifiable {

    /// The wire format identifier, so a reader can reject a file that merely
    /// has the right extension before trusting a single other field.
    public static let schemaName = "mary.behavior"

    /// The current format version. Bump when a field's MEANING changes;
    /// adding a tolerated optional does not need one.
    public static let currentSchemaVersion = 1

    public var schema: String
    public var schemaVersion: Int

    /// The user turn's own UUID. See the file header — not a new identity.
    public var id: UUID

    public var openedAt: Date
    public var sealedAt: Date?
    public var sealedReason: EpisodeSealReason?

    public var input: BehavioralInput
    public var output: BehavioralOutput
    public var provenance: EpisodeProvenance

    public init(
        id: UUID,
        openedAt: Date,
        sealedAt: Date? = nil,
        sealedReason: EpisodeSealReason? = nil,
        input: BehavioralInput,
        output: BehavioralOutput = .init(),
        provenance: EpisodeProvenance
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
    }

    /// Whether this episode has stopped taking actions.
    public var isSealed: Bool { sealedReason != nil }

    /// Whether anything actually ran. The natural first filter for a training
    /// set that wants only acted turns — and the natural inverse for one that
    /// wants to learn restraint.
    public var didAct: Bool {
        output.actions.contains { $0.disposition.didRun }
    }

    private enum CodingKeys: String, CodingKey {
        case schema, schemaVersion, id, openedAt, sealedAt, sealedReason
        case input, output, provenance
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
    }
}

/// The codec's own encoder and decoder.
///
/// One spelling, in one place, because byte-stability is a property the tests
/// assert and the store depends on: two identical episodes must produce two
/// identical lines. `.sortedKeys` for determinism, ISO-8601 dates so a row
/// stays readable by anything, and `.withoutEscapingSlashes` so a file path
/// in a document key reads as a path.
///
/// NEWLINES ARE THE RECORD SEPARATOR — the store writes one episode per line
/// — so the encoder must never pretty-print. That is not a style preference
/// here; a pretty-printed episode would corrupt the file it is appended to.
///
/// FRACTIONAL SECONDS ARE NOT OPTIONAL, and this is why the strategy is
/// hand-built rather than `.iso8601`. That built-in strategy formats to whole
/// seconds and silently discards the rest — which would round every timestamp
/// in the dataset to the nearest second. Actions inside one turn routinely
/// land 100–300 ms apart, so whole seconds would collapse them to identical
/// stamps and destroy the ORDER of a sequence, which is the one property the
/// output half exists to record. It would also break the round trip: a frame
/// captured at `x.8` would decode as `x.0` and no longer equal itself.
public enum BehavioralCodec {

    /// ISO-8601 with milliseconds, in UTC. Formatters are expensive to build
    /// and safe to share once configured, so this one is made once.
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Accepts a stamp with OR without fractional seconds, so a row written
    /// by hand — or by an older build — still opens.
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

    /// One episode as one line of JSON, with no trailing newline — the store
    /// owns the separator.
    public static func line(_ episode: BehavioralEpisode) throws -> Data {
        try encoder().encode(episode)
    }

    public static func episode(from line: Data) throws -> BehavioralEpisode {
        try decoder().decode(BehavioralEpisode.self, from: line)
    }
}

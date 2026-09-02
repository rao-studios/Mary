//
//  BehavioralAction.swift
//  MaryFoundation
//
//  WHAT: One performable action (intent, skill, target, adapters). Record adds outcome.
//  IN:   AbilityRuntime chokepoint → one record.
//  OUT:  log, chip, inspector, Totem, BehavioralEpisode.
//  PIN:  Synthesized Codable (observed, not `.mary` digest). One type at one chokepoint.
//

import Foundation

/// Outcome vocabulary. Maps from SkillRunStatus via `init(_ status:)`.
/// PIN: Dataset outlives the runtime enum; unknown decodes, never fails the episode.
public enum BehavioralDisposition: String, Codable, Hashable, Sendable, CaseIterable {
    /// Ran.
    case succeeded
    /// Attempted, did not work.
    case failed
    /// Refused before run. Distinct from `failed`: nothing attempted.
    case blocked
    /// Handed off; outcome not yet known.
    case deferred
    /// Stopped part-way (barge-in / superseding turn).
    case cancelled
    /// Parked for spoken go-ahead. Later episode carries the run via `confirmationID`.
    case requestedConfirmation
    /// Still running at write. Only quit-flush mid-action.
    case unsettled
    /// Unknown to this build. Decode-only.
    case unknown

    /// Exhaustive SkillRunStatus map. New case must compile here, not default unknown.
    public init(_ status: SkillRunStatus) {
        switch status {
        case .requested: self = .requestedConfirmation
        case .running: self = .unsettled
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .blocked: self = .blocked
        case .deferred: self = .deferred
        case .cancelled: self = .cancelled
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BehavioralDisposition(rawValue: raw) ?? .unknown
    }

    /// Action ran. `foundNothing` reads still `succeeded`.
    public var didRun: Bool {
        switch self {
        case .succeeded, .failed, .deferred, .cancelled, .unsettled: return true
        case .blocked, .requestedConfirmation, .unknown: return false
        }
    }
}

/// WHO ASKED. A chip is a receipt for an act; this says whose act it was.
/// PIN: Decode-tolerant, `BehavioralDisposition`'s own pattern — a record
///      written before this existed, or by a newer build, must still open.
public enum ActionInitiator: String, Codable, Hashable, Sendable, CaseIterable {
    /// The model called it.
    case model
    /// Mary's own pre-read — the ONLY runtime path that bypasses the offer
    /// ledger's authorization claim over the model. See `AbilityRuntime`'s
    /// `RuntimeRead` for the gate this provenance now backs.
    case maryRead
    /// Mary acting unattended (the idle Life pulse). Still faces the offer
    /// ledger like any other act — this is provenance, never a bypass.
    case maryAct
    /// Unknown to this build. Decode-only.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActionInitiator(rawValue: raw) ?? .unknown
    }

    /// The current dispatch's provenance, for the one chokepoint that stamps
    /// every `BehavioralActionRecord`. Bound around a pre-read or an
    /// unattended act; left at its default everywhere else.
    @TaskLocal public static var current: ActionInitiator = .model
}

/// Performable action. Outcome lives on BehavioralActionRecord.
public struct BehavioralAction: Codable, Hashable, Sendable {

    /// Invocation name as the model saw it, not Skill id.
    public var intention: String

    /// Canonical sorted-key JSON. String for byte-stable identical rows.
    public var argumentsJSON: String

    /// Frozen AbilitySkillReference (version + digest). Live lookup would drift.
    public var skill: AbilitySkillReference

    /// Target element + frame. Nil if no surface. Re-find via AXElementRecord.identity.
    public var target: AXElementRecord?

    /// Adapters that fulfilled this, primary first. Ladder may list more than one.
    public var adapters: [AdapterID]

    public init(
        intention: String,
        argumentsJSON: String = "{}",
        skill: AbilitySkillReference,
        target: AXElementRecord? = nil,
        adapters: [AdapterID] = []
    ) {
        self.intention = intention
        self.argumentsJSON = argumentsJSON
        self.skill = skill
        self.target = target
        self.adapters = adapters
    }
}

/// Action plus outcome. One record; every consumer reads this.
public struct BehavioralActionRecord: Codable, Hashable, Sendable, Identifiable {

    /// Wire run id. Lane-minted so the chip and this record match.
    public var id: String

    public var action: BehavioralAction

    public var disposition: BehavioralDisposition

    /// Spoken summary for a person.
    public var summary: String

    /// Read ran, found nothing. Not a failure; not a disposition.
    public var foundNothing: Bool

    /// Undo affordance for the log.
    public var undoable: Bool

    /// Touched container (window / document key) when the element is not enough.
    public var containerKey: String?

    /// Joins parked `.requestedConfirmation` to the later run record.
    public var confirmationID: UUID?

    public var startedAt: Date
    public var finishedAt: Date?

    /// Who asked for this act. Defaulted so every existing call site — and
    /// every fixture, and every persisted record from before this field
    /// existed — reads `.model` without change.
    public var initiator: ActionInitiator

    public init(
        id: String,
        action: BehavioralAction,
        disposition: BehavioralDisposition,
        summary: String,
        foundNothing: Bool = false,
        undoable: Bool = false,
        containerKey: String? = nil,
        confirmationID: UUID? = nil,
        startedAt: Date,
        finishedAt: Date? = nil,
        initiator: ActionInitiator = .model
    ) {
        self.id = id
        self.action = action
        self.disposition = disposition
        self.summary = summary
        self.foundNothing = foundNothing
        self.undoable = undoable
        self.containerKey = containerKey
        self.confirmationID = confirmationID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.initiator = initiator
    }

    /// Lane declined before dispatch. Recorded — refusal is behaviour.
    /// Announced, not settled. Same id as the later record. No target yet.
    public static func requested(
        id: String,
        action: BehavioralAction,
        at date: Date = Date()
    ) -> BehavioralActionRecord {
        BehavioralActionRecord(
            id: id,
            action: action,
            disposition: .unsettled,
            summary: "",
            startedAt: date)
    }

    public static func refused(
        id: String,
        action: BehavioralAction,
        reason: String,
        at date: Date = Date()
    ) -> BehavioralActionRecord {
        BehavioralActionRecord(
            id: id,
            action: action,
            disposition: .blocked,
            summary: reason,
            startedAt: date,
            finishedAt: date)
    }

    /// Duration when finished.
    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, disposition, summary, foundNothing, undoable
        case containerKey, confirmationID, startedAt, finishedAt, initiator
    }

    /// Absent optionals decode; older files still open.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        action = try values.decode(BehavioralAction.self, forKey: .action)
        disposition = try values.decode(BehavioralDisposition.self, forKey: .disposition)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        foundNothing = try values.decodeIfPresent(Bool.self, forKey: .foundNothing) ?? false
        undoable = try values.decodeIfPresent(Bool.self, forKey: .undoable) ?? false
        containerKey = try values.decodeIfPresent(String.self, forKey: .containerKey)
        confirmationID = try values.decodeIfPresent(UUID.self, forKey: .confirmationID)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
        initiator = try values.decodeIfPresent(ActionInitiator.self, forKey: .initiator) ?? .model
    }
}

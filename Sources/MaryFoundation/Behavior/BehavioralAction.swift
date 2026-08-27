//
//  BehavioralAction.swift
//  MaryFoundation
//
//  THE OUTPUT HALF OF THE BEHAVIORAL CODEC — one action, said once.
//
//  An action is: *this frame, this plugin, this intention, these adapters.*
//  A target element carrying its own geometry; the Skill reference that says
//  which package, ability and adapter answered; the invocation name the model
//  used; and the trail of adapters that actually did the work.
//
//  TWO SHAPES, AND THE DIFFERENCE IS THE POINT. `BehavioralAction` is what
//  can be EMITTED — everything needed to perform it, and nothing about how it
//  went. `BehavioralActionRecord` wraps one with what happened. A future
//  model predicting Mary's behaviour produces the former; this build produces
//  the latter by executing and observing. They are the same vocabulary read
//  in two directions, which is exactly what makes a recorded session usable
//  as training material for a predicted one.
//
//  WHY ONE TYPE AND NOT SIX. Bonnie composed up to six disjoint records for a
//  single executed action — an execution-log row, a conversation chip, a
//  receipt in a trace, a lane outcome, a memory deposit — at four different
//  places, correlated by three different keys. They drifted, provably: the
//  log recorded the statically-preferred adapter while the chip recorded the
//  one the turn actually chose, so the two surfaces could name different
//  providers for the same run. And none of the six carried a target element,
//  a frame, or the context that prompted it. Mary composes ONE record at ONE
//  chokepoint, and every consumer — the log, the chip, the inspector, the
//  memory deposit, the dataset — reads that. Disagreement is not fixed here;
//  it is made unrepresentable.
//
//  OBSERVED, NEVER AUTHORED — so plain synthesized `Codable`, not the strict
//  `rejectUnknownKeys` decoder. That decoder protects a `.mary` package's
//  integrity digest, where an ignored byte would be a byte missing from a
//  verified hash. These records are written by this build about its own
//  behaviour; tolerance is what lets an older reader open a newer file. See
//  `AXFrame.swift`, which makes the same call for the same reason.
//

import Foundation

/// How an action turned out.
///
/// Mary's own vocabulary rather than `SkillRunStatus` re-used directly, for
/// two reasons that both point the same way. The dataset outlives the enum:
/// a status case added or renamed in the runtime must not change what an
/// already-written episode means, so the mapping between them is explicit and
/// total (`init(_ status:)`) instead of implied by a shared raw value. And a
/// reader from a future build can meet a disposition this build never wrote —
/// which decodes as `.unknown` rather than failing the whole episode.
public enum BehavioralDisposition: String, Codable, Hashable, Sendable, CaseIterable {
    /// It happened.
    case succeeded
    /// It was attempted and did not work.
    case failed
    /// Refused before running — a capability check, a veto, an unoffered
    /// invocation. Distinct from `failed`: nothing was attempted.
    case blocked
    /// Handed off to something that reports later, so this record's outcome
    /// is genuinely not yet known rather than merely unrecorded.
    case deferred
    /// Stopped part-way — a barge-in, a superseding turn.
    case cancelled
    /// Parked awaiting the user's spoken go-ahead. The action did NOT run;
    /// when the user agrees, a second record in the following episode carries
    /// the run, linked by `confirmationID`.
    case requestedConfirmation
    /// Still running when the record was written. Unreachable at settle time
    /// and reachable exactly one way: an episode flushed because the app was
    /// quitting mid-action.
    case unsettled
    /// A disposition this build does not know. Decode-only — never written.
    case unknown

    /// The total map from the runtime's status vocabulary.
    ///
    /// An exhaustive switch on purpose: adding a `SkillRunStatus` case must
    /// fail to compile here, so the decision about what it means to the
    /// dataset is made deliberately rather than defaulting to `.unknown`.
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

    /// Whether the world changed. `foundNothing` reads are `succeeded` too —
    /// the question is whether the action ran, not whether it found anything.
    public var didRun: Bool {
        switch self {
        case .succeeded, .failed, .deferred, .cancelled, .unsettled: return true
        case .blocked, .requestedConfirmation, .unknown: return false
        }
    }
}

/// One action, in the form that can be performed.
///
/// This is the unit a future model emits — alone for a single step, in
/// sequence for a whole procedure. Everything needed to carry it out is here
/// and nothing about how it went, which is what makes the same type safe to
/// predict with and to record with.
public struct BehavioralAction: Codable, Hashable, Sendable {

    /// What was asked for, in the name the model calls it — `type_at_cursor`,
    /// `read_note`. The invocation name, not the Skill id: this is the word
    /// that appeared in the tool roster, so a dataset row reads the way the
    /// turn read.
    public var intention: String

    /// The arguments, canonical JSON with sorted keys.
    ///
    /// A string rather than a decoded dictionary because arguments are
    /// per-Skill and open-ended, and because byte-stability matters more than
    /// structure here: two identical calls must produce two identical rows.
    public var argumentsJSON: String

    /// WHICH PLUGIN ANSWERED — package, ability, skill, adapter, provider,
    /// frozen at the moment of the call.
    ///
    /// Frozen matters. A package can be edited, reinstalled or uninstalled
    /// between an action and anybody reading about it; a live lookup by id
    /// would then describe the wrong thing, or nothing. The reference carries
    /// the package version and digest so a row remains legible against a
    /// package that no longer exists.
    public var skill: AbilitySkillReference

    /// WHAT WAS ACTED UPON — the element, with its frame.
    ///
    /// Nil for an action with no surface: a cognitive Skill that only thinks,
    /// a read answered from held context. Present, this is the geometry half
    /// of the codec — and it is EVIDENCE, not an address. Re-finding is by
    /// `AXElementRecord.identity`; the frame says where it was, at
    /// `frame.capturedAt`, for aiming and for reasoning about layout.
    public var target: AXElementRecord?

    /// The adapters that fulfilled this, primary first.
    ///
    /// Usually one. More than one when a fulfilment fell through a ladder —
    /// a prose write that landed by keystroke names the prose surface and
    /// then the typer. The trail is what makes "how did she actually do
    /// that?" answerable from the record instead of from a log.
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

/// One action, and what happened to it.
///
/// The single record every consumer reads: the execution log, the
/// conversation chip and its inspector, the memory deposit, and one row of
/// the behavioural dataset. Composed once, at one chokepoint.
public struct BehavioralActionRecord: Codable, Hashable, Sendable, Identifiable {

    /// The invocation id from the model's own call, so a result can be
    /// matched to the ask that is already on screen. Minted by the lane, not
    /// here — a record and the chip it updates must share this exactly.
    public var id: String

    public var action: BehavioralAction

    public var disposition: BehavioralDisposition

    /// What Mary would say about it. Written for a person, not a parser.
    public var summary: String

    /// A read that ran correctly and found nothing.
    ///
    /// Separate from the disposition because it is not a failure and must
    /// never be spoken as one — "there are no notes open" is a true answer.
    /// Keeping it out of `disposition` also keeps the disposition about
    /// whether the action ran.
    public var foundNothing: Bool

    /// Whether this could be taken back. Drives the log's undo affordance.
    public var undoable: Bool

    /// The container this touched — a window handle, a document key.
    ///
    /// The answer to "which note did she just change?" when the target
    /// element alone does not say it.
    public var containerKey: String?

    /// Links the two halves of a confirmed action.
    ///
    /// A parked action and its later replay are two records in two episodes:
    /// the asking one holds `.requestedConfirmation`, the executing one holds
    /// the run. Same id on both. Without this the dataset would show a
    /// question with no answer and an answer with no question.
    public var confirmationID: UUID?

    public var startedAt: Date
    public var finishedAt: Date?

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
        finishedAt: Date? = nil
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
    }

    /// A refusal that never reached the runtime.
    ///
    /// Some actions are declined by the lane before dispatch is called at all
    /// — a revision veto, an invocation that was never offered this turn. The
    /// chokepoint cannot see those, so they are composed here, and they are
    /// recorded rather than dropped: a refusal is behaviour, and a dataset
    /// that only contains what Mary agreed to do teaches nothing about what
    /// she declines.
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

    /// How long it took, when it finished.
    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, disposition, summary, foundNothing, undoable
        case containerKey, confirmationID, startedAt, finishedAt
    }

    /// Tolerant: every optional-with-default field may be absent, so a file
    /// written by an older build still opens.
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
    }
}

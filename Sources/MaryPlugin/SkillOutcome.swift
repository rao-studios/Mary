//
//  SkillOutcome.swift
//  MaryPlugin
//
//  WHAT: Return type of one Skill binding.
//  IN:   every adapter
//  OUT:  Ability runtime / BehavioralActionRecord
//  PIN:  Lives with the contract — plugin authors write it; the engine passes it.
//

import Foundation

/// What a Skill result means for memory. Declared by the binding.
/// OUT: SkillOutcome.archivePolicy
public enum ArchivePolicy: String, Sendable, Equatable {
    /// Something that happened. Each occurrence is its own document.
    case episodic
    /// Current state of the thing in view. The next statement replaces this one.
    case stateSnapshot
    /// Not worth remembering.
    case none
}


/// What a passage edit did to the document. `ok` cannot carry this:
/// `ok: false` looks retryable; `ok: true` used to speak "Done" unconfirmed.
public enum EditDisposition: String, Sendable, Equatable {
    /// Verified against the document: the change is there.
    case landed
    /// Sent, nothing confirmed. Never retry; never "Done".
    case unconfirmed
    /// Nothing differed; the document was not touched.
    case unchanged
}

/// What a keyboard typing run delivered. Nil off the typing path.
/// PIN: paused/focus-lost is `ok: true` but not a fully delivered draft.
public enum TypingDisposition: String, Sendable, Equatable {
    /// The whole passage landed.
    case completed
    /// Some landed; remainder saved. resume_typing continues.
    case partialResumable
}

public struct SkillOutcome: Sendable {
    public var ok: Bool
    /// Terminal state for receipts. Schema-policy denial is `.blocked`.
    public var status: SkillRunStatus
    /// Spoken back via the confirmation round.
    public var summary: String
    /// `summary` is a fire-and-forget ack; the real result lands later.
    /// PIN: brain will not archive a deferred ack into Totem.
    public var deferred: Bool
    /// Binding's memory declaration. Default `.episodic`.
    public var archivePolicy: ArchivePolicy
    /// The look ran and what was asked for is not there. `ok` stays true.
    /// PIN: not `ok: false` — that would speak a failure and invite a retry.
    public var foundNothing: Bool
    /// Passage this result is about — `[S1]`, minted by PassageRegistry.
    /// OUT: AmbientFact / AbilityRuntime.registerRead (files the world's fact).
    public var passageHandle: String?
    /// Package/Ability/Skill identity. Confirmation replays carry the frozen one.
    public var skillReference: AbilitySkillReference?
    /// Typed outputs keyed by declared output-port name.
    public var typedOutputs: [String: ValueEnvelope]
    /// What an edit did. Nil off the passage-edit path.
    /// OUT: EditReport / LaneOutcome mapping (both sites must carry it).
    public var editDisposition: EditDisposition?
    /// Adapter already filed this read's ambient fact. Dispatcher must not file a second.
    public var ambientDeposited: Bool
    /// Typing run delivery. Nil off the keyboard path. See TypingDisposition.
    public var typingDisposition: TypingDisposition?
    /// The asked-for change happened; the turn has nothing left.
    /// PIN: set only on proven effect. `false` when merely dispatched.
    public var landed: Bool

    /// A deterministic resolver committed to its best guess rather than
    /// refuse (`SpokenTitleCommitContext` only). `summary` MUST state the
    /// interpretation, never claim certainty — the "correctable in one
    /// word" contract this field exists to preserve. The confidence-dispatch
    /// epilogue reads this to force the summary to speak even when `ok`.
    public var committedGuess: Bool

    /// Element (with frame) as it was at the moment of acting.
    /// PIN: evidence, not an address — actuation re-reads by identity.
    public var target: AXElementRecord?

    /// Adapters that fulfilled this, primary first. Ladder fallbacks list each hop.
    public var adapterTrail: [AdapterID]

    /// THE APPLICATION THIS ACT LANDED IN, as its logical id — the proof a
    /// habit is learned from. Nil when the act targeted no application (a
    /// catalog lookup, a cognitive Skill) or when the adapter cannot say which
    /// one answered. PIN: evidence, never a request — an `app` ARGUMENT says
    /// where a caller aimed, and aiming is not landing.
    public var applicationID: String?

    public init(
        ok: Bool,
        summary: String,
        status: SkillRunStatus? = nil,
        deferred: Bool = false,
        archivePolicy: ArchivePolicy = .episodic,
        foundNothing: Bool = false,
        passageHandle: String? = nil,
        skillReference: AbilitySkillReference? = nil,
        typedOutputs: [String: ValueEnvelope] = [:],
        editDisposition: EditDisposition? = nil,
        ambientDeposited: Bool = false,
        typingDisposition: TypingDisposition? = nil,
        landed: Bool = false,
        target: AXElementRecord? = nil,
        adapterTrail: [AdapterID] = [],
        committedGuess: Bool = false,
        applicationID: String? = nil
    ) {
        self.ok = ok
        self.summary = summary
        self.status = status ?? (deferred ? .deferred : (ok ? .succeeded : .failed))
        self.deferred = deferred
        self.archivePolicy = archivePolicy
        self.foundNothing = foundNothing
        self.passageHandle = passageHandle
        self.skillReference = skillReference
        self.typedOutputs = typedOutputs
        self.editDisposition = editDisposition
        self.ambientDeposited = ambientDeposited
        self.typingDisposition = typingDisposition
        self.landed = landed
        self.target = target
        self.adapterTrail = adapterTrail
        self.committedGuess = committedGuess
        self.applicationID = applicationID
    }
}
